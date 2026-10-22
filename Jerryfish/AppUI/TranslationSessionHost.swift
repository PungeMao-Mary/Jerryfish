import SwiftUI
import Translation

// ============================================================
// 无头翻译会话宿主
//
// macOS 15 的 `TranslationSession` 只能通过 SwiftUI 的 `.translationTask` 修饰符获得，
// 且只在 action 闭包存活期间有效。为了让「按需翻译」（点按钮 / 截屏 / PDF 批注）
// 随时可用，这里把宿主挂到窗口根视图上：
//
//   - 宿主本身不渲染任何内容（透明、零尺寸）；
//   - 闭包内把 session 交给 `TranslationService.serve(session:)` 长期持有；
//   - 多个窗口同时挂载时，后到者会「顶掉」先到者，旧闭包自行退出（不会丢任务）。
// ============================================================

struct TranslationSessionHost: ViewModifier {

    let service: TranslationService

    func body(content: Content) -> some View {
        content
            .translationTask(service.configuration) { session in
                // session 只在本闭包与 serve 内部使用，绝不跨隔离域传递
                await service.serve(session: session)
            }
            .task {
                // 先解析出系统真正安装的语言对，再建立 configuration
                await service.startTranslationTaskIfNeeded()
            }
    }
}

extension View {
    /// 在窗口根视图上挂载翻译会话宿主。
    func translationSessionHost(_ service: TranslationService) -> some View {
        modifier(TranslationSessionHost(service: service))
    }
}
