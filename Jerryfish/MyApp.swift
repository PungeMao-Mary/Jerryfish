import AppKit
import SwiftUI

// ============================================================
// 应用入口
//
// - `WindowGroup(id: "main")` 主翻译窗口；
// - `WindowGroup(id: "pdf", for: URL.self)` PDF 翻译窗口（每个 PDF 一个窗口）；
// - `AppDelegate` 在 NSApplication 生命周期内注册全局热键，
//   保证主窗口关闭 / 隐藏后 ⌘⇧A 依然可用。
//   Info.plist：LSUIElement = NO（保留 Dock 图标，不做纯后台 agent）。
//
// 注意：`@NSApplicationDelegateAdaptor` 在 macOS 26+ 上不会把自定义 delegate
// 装到 `NSApp.delegate`（那里是 SwiftUI 自己的包装器），所以热键与 UI 之间
// 通过 `HotkeyRouter` 显式路由，绝不依赖 `NSApp.delegate as? AppDelegate`。
// ============================================================

@main
struct AcademicTranslatorApp: App {

    /// 应用显示名（统一使用 Jerryfish）。
    static let appName = "Jerryfish"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel: AppViewModel
    @State private var translationService: TranslationService

    init() {
        let service = TranslationService()
        _translationService = State(initialValue: service)
        _viewModel = State(initialValue: AppViewModel(translationService: service))
    }

    var body: some Scene {
        // MARK: 主窗口（单例）
        //
        // 用 `Window` 而不是 `WindowGroup`：
        //   1. 翻译器只需要一个主窗口，`WindowGroup` 每次 `openWindow(id:)` 都会新建窗口，
        //      热键 / Dock / 打开文档反复触发就会攒出一堆主窗口；
        //   2. 更关键的是：macOS 收到「打开文档」事件时，SwiftUI 会给**第一个 WindowGroup**
        //      自动开一个窗口来承载文档，导致「打开一个 PDF 就多出一个空主窗口」（实测）。
        //      两个场景都用单例 `Window` 后，它没有可以乱开的目标。
        Window(Self.appName, id: "main") {
            ContentView(viewModel: viewModel, translationService: translationService)
                .translationSessionHost(translationService)
        }
        .defaultSize(width: 980, height: 660)
        // 单例 Window 场景默认不会在启动时出现，必须显式声明为「启动即展示」
        .defaultLaunchBehavior(.presented)
        .commands {
            AppCommands(viewModel: viewModel)
        }

        // MARK: PDF 翻译窗口（单例二级窗口）
        //
        // 同样用单例 `Window`：只在显式 openWindow 时出现，符合「一个二级独立窗口」的定位。
        Window(Self.appName, id: "pdf") {
            if let url = viewModel.activePDFURL {
                PDFTranslationHostView(
                    pdfURL: url,
                    translationService: translationService,
                    onOpenAnotherPDF: { viewModel.choosePDFAndOpen() }
                )
                .id(url)
                .translationSessionHost(translationService)
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        String(localized: "未选择 PDF"),
                        systemImage: "doc.questionmark",
                        description: Text(String(localized: "请选择需要翻译批注的英文 PDF。"))
                    )
                    Button {
                        viewModel.choosePDFAndOpen()
                    } label: {
                        Label(String(localized: "打开 PDF…"), systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .defaultSize(width: 1120, height: 820)
        // 二级窗口只在显式 openWindow 时出现
        .defaultLaunchBehavior(.suppressed)
    }
}

// MARK: - 菜单

struct AppCommands: Commands {

    @Environment(\.openWindow) private var openWindow

    @Bindable var viewModel: AppViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "显示主窗口")) {
                openWindow(id: "main")
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(String(localized: "打开 PDF 翻译…")) {
                viewModel.choosePDFAndOpen()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "设置…")) {
                // 主窗口可能已关闭：先确保它有地方承载设置 Sheet
                openWindow(id: "main")
                viewModel.isSettingsPresented = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu(String(localized: "翻译")) {
            Button(String(localized: "截屏翻译")) {
                viewModel.beginCaptureFlow()
            }
            // 与全局热键保持一致；全局热键由 Carbon 注册，不受菜单快捷键影响
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button(String(localized: "翻译当前输入")) {
                Task { await viewModel.translateCurrentInput() }
            }
            .keyboardShortcut(.return, modifiers: .command)

            Divider()

            Button(String(localized: "交换原文与译文")) {
                viewModel.swapInputAndOutput()
            }
            Button(String(localized: "清空")) {
                viewModel.clearAll()
            }

            Divider()

            // 刻意不加 .disabled：Commands 的 disabled 在构建时求值，
            // 那时若还没打开 PDF 就会被判为禁用，连快捷键一起失效（实测踩到）。
            // 没有活跃文档时改为引导用户先打开一个 PDF。
            Button(String(localized: "翻译 PDF 全文")) {
                if let action = PDFCommandRouter.shared.translateAll {
                    action()
                } else {
                    viewModel.choosePDFAndOpen()
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button(String(localized: "清除 PDF 译文批注")) {
                PDFCommandRouter.shared.clearTranslations?()
            }

            Divider()

            Button(String(localized: "下载 / 修复离线语言包")) {
                Task { await viewModel.downloadLanguagePack() }
            }
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let hotkeys = GlobalHotkeyManager.shared
    private var windowObservers: [NSObjectProtocol] = []

    /// 让所有窗口都不参与 macOS 的「恢复窗口」。
    ///
    /// 为什么需要：macOS 默认会「重新打开上次的窗口」。如果用户上次只开着 PDF 窗口
    /// （或把主窗口关了），下次启动就会**只恢复那一个窗口、主界面反而不出现**，
    /// 看起来像「打开只有一个未选择 PDF」。
    /// （注意：不能改用 `Scene.restorationBehavior(.disabled)`——实测那样 SwiftUI
    ///  连初始窗口都不会创建，启动后一个窗口都没有。）
    private func disableWindowRestoration() {
        for window in NSApp.windows { window.isRestorable = false }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                (note.object as? NSWindow)?.isRestorable = false
            }
            windowObservers.append(token)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        disableWindowRestoration()
        // 关键：注册在 NSApplication 生命周期内，主窗口关闭后依然监听全局事件
        hotkeys.register {
            // 刻意不激活本应用：保持用户正在阅读的窗口在前台与最上层
            HotkeyRouter.shared.requestCapture()
        }
    }

    /// 系统要求本应用打开文件（`open -a Jerryfish x.pdf`、双击、拖到 Dock）。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return }
        HotkeyRouter.shared.requestOpenPDF(pdf)
    }

    /// 关闭所有窗口后不退出：全局热键必须继续在后台工作。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点击 Dock 图标时若无可见窗口，则重新打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            HotkeyRouter.shared.requestMainWindow()
        }
        return true
    }
}
