import AppKit
import SwiftUI

// ============================================================
// 窗口根视图
//
// 除了承载主界面，还负责把「全局热键 → SwiftUI 动作」接起来：
//   - HotkeyRouter.onCaptureRequested → AppViewModel.beginCaptureFlow()
//   - HotkeyRouter.onOpenMainWindow  → openWindow(id: "main")
//
// 不能通过 `NSApp.delegate as? AppDelegate` 取自定义 delegate：
// macOS 26+ 上 `@NSApplicationDelegateAdaptor` 把它包装成了 `SwiftUI.AppDelegate`。
// ============================================================

struct ContentView: View {

    var viewModel: AppViewModel
    var translationService: TranslationService

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainTranslatorView(viewModel: viewModel)
            .onAppear {
                let model = viewModel
                let router = HotkeyRouter.shared
                router.onCaptureRequested = { [weak model] in
                    model?.beginCaptureFlow()
                }
                // 主窗口是单例 Window：openWindow 只会前置，不会重复开窗
                router.onOpenMainWindow = {
                    openWindow(id: "main")
                }
                router.onOpenPDF = { url in
                    model.activePDFURL = url
                    // PDF 场景是单例 Window，重复调用只会前置，不会重复开窗
                    openWindow(id: "pdf")
                }
                Task { await model.bootstrapEngine() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await viewModel.refreshEngineAvailability() }
            }
    }
}
