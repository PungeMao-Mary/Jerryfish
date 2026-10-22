import AppKit
import Foundation
import KeyboardShortcuts

// ============================================================
// 后台全局热键服务
//
// 选型：直接集成社区工业标准库 `KeyboardShortcuts`（Sindre Sorhus）。
//   - 底层使用 Carbon `RegisterEventHotKey`，**不需要辅助功能（Accessibility）权限**；
//   - 沙盒（App Sandbox）下同样可用；
//   - `Recorder` 控件自带冲突检测与录制 UI。
//
// 严禁自行用 Carbon C API 重造轮子。
//
// 生命周期：由 `AppDelegate`（NSApplicationDelegate）持有并在
// `applicationDidFinishLaunching` 时注册，因此主窗口关闭 / 隐藏后仍可响应。
// ============================================================

nonisolated extension KeyboardShortcuts.Name {
    /// 全局「截屏翻译」快捷键，默认 ⌘ ⇧ A。
    static let captureAndTranslate = Self(
        "captureAndTranslate",
        initial: .init(.a, modifiers: [.command, .shift])
    )
}

// MARK: - 热键路由

/// 热键 → UI 的动作路由器。
///
/// 为什么不直接用 `NSApp.delegate as? AppDelegate`？
/// 因为 `@NSApplicationDelegateAdaptor` 在 macOS 26+ 上 **不会** 把自定义 delegate
/// 装到 `NSApp.delegate`（那里是 `SwiftUI.AppDelegate` 包装器），
/// 因此必须通过这个显式路由把「热键触发的动作」交给 SwiftUI 层。
@MainActor
final class HotkeyRouter {

    static let shared = HotkeyRouter()

    /// 热键按下时执行（由根视图注入：开始截屏翻译）。
    var onCaptureRequested: (() -> Void)?
    /// 需要把主窗口带回前台时执行（由根视图注入 `openWindow(id: "main")`）。
    var onOpenMainWindow: (() -> Void)?
    /// 需要在 PDF 窗口中打开某个文档时执行（由根视图注入）。
    var onOpenPDF: ((URL) -> Void)?

    private init() {}

    /// 触发截屏翻译；若 UI 尚未接管则退化为「打开主窗口」，避免按键无反应。
    func requestCapture() {
        if let handler = onCaptureRequested {
            handler()
        } else {
            requestMainWindow()
        }
    }

    /// 打开一个 PDF（来自 `open -a / 双击 / 拖到 Dock` 等系统事件）。
    func requestOpenPDF(_ url: URL) {
        if let handler = onOpenPDF {
            handler(url)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            NSWorkspace.shared.open(url)   // 交给系统默认程序，至少不让用户没反应
        }
    }

    func requestMainWindow() {
        if let opener = onOpenMainWindow {
            opener()
        } else if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - PDF 动作路由

/// 菜单栏动作 → PDF 窗口的命令通道。
///
/// PDF 的翻译状态属于某一个 PDF 窗口（视图内部 @State），菜单无法直接访问，
/// 因此由 PDF 窗口在出现时注册命令、消失时注销。
@MainActor
final class PDFCommandRouter {

    static let shared = PDFCommandRouter()

    var translateAll: (() -> Void)?
    var clearTranslations: (() -> Void)?
    var openPDF: (() -> Void)?

    private init() {}

    var hasActiveDocument: Bool { translateAll != nil }

    func reset() {
        translateAll = nil
        clearTranslations = nil
    }
}

// MARK: - 热键管理器

/// 全局热键管理器。
public final class GlobalHotkeyManager {

    public static let shared = GlobalHotkeyManager()

    /// 当前是否已注册（供设置界面展示）。
    public private(set) var isRegistered = false

    private var handler: (() -> Void)?

    public init() {}

    // MARK: - 注册 / 注销

    /// 在主程序生命周期内注册全局热键。
    ///
    /// - Parameter handler: 触发时回调（一定在主线程）。
    public func register(handler: @escaping () -> Void) {
        self.handler = handler
        KeyboardShortcuts.onKeyUp(for: .captureAndTranslate) { [weak self] in
            self?.handler?()
        }
        KeyboardShortcuts.enable(.captureAndTranslate)
        isRegistered = true
    }

    /// 暂时停用（例如正在录制新快捷键、或用户关闭了该功能）。
    public func suspend() {
        KeyboardShortcuts.disable(.captureAndTranslate)
        isRegistered = false
    }

    public func resume() {
        guard handler != nil else { return }
        KeyboardShortcuts.enable(.captureAndTranslate)
        isRegistered = true
    }

    public func unregister() {
        KeyboardShortcuts.disable(.captureAndTranslate)
        handler = nil
        isRegistered = false
    }

    // MARK: - 状态查询

    /// 当前快捷键能否被读取（nil = 用户清除了快捷键）。
    public var currentShortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: .captureAndTranslate)
    }

    /// 恢复默认 ⌘ ⇧ A。
    public func restoreDefaultShortcut() {
        KeyboardShortcuts.reset(.captureAndTranslate)
    }

    public func isEnabledByUser() -> Bool {
        KeyboardShortcuts.isEnabled(for: .captureAndTranslate)
    }
}
