import AppKit
import SwiftUI

// ============================================================
// 主界面文本编辑器（NSTextView 包装）
//
// 为什么不用 SwiftUI 的 `TextEditor`：
//   1. `TextEditor` 无法设置占位符。用 ZStack 叠一层 SwiftUI `Text` 时，
//      占位符与光标分属两套排版系统（SwiftUI Text vs TextKit），
//      即使 padding 数值相同也会有 2~3pt 残差 —— 也就是「光标与提示文字错位」。
//      这里改为**由 NSTextView 自己在 `textContainerOrigin` 处绘制占位符**，
//      与光标、首行文字共用同一套排版，像素级一致。
//   2. `TextEditor` 默认开启智能引号 / 破折号 / 文本替换，会篡改学术原文
//      （例如把 `"` 变成 `“`、把 `--` 变成 `—`）。
//   3. 便于精确控制撤销、行距与首行位置。
// ============================================================

/// 会把占位符画在「文字起点」上的 NSTextView。
final class PlaceholderTextView: NSTextView {

    var placeholder: String = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = AcademicTextEditor.lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: AcademicTextEditor.fontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: style,
        ]
        // textContainerOrigin 就是文字排版原点：与光标 / 首行文字严格同源
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: attributes)
    }
}

struct AcademicTextEditor: NSViewRepresentable {

    @Binding var text: String
    var placeholder: String
    var isEditable: Bool = true
    /// 视图出现时自动获取焦点（仅执行一次）
    var autoFocus: Bool = false

    /// 文本绘制起点（相对视图左上角）。
    static let textInset = NSSize(width: 6, height: 8)
    static let fontSize: CGFloat = 13.5
    static let lineSpacing: CGFloat = 3

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView(frame: .zero)
        textView.placeholder = placeholder

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        // 学术原文绝不能被自动替换
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        Self.applyTypography(to: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        context.coordinator.shouldAutoFocus = autoFocus
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }

        if textView.placeholder != placeholder { textView.placeholder = placeholder }

        if textView.string != text {
            // 外部改动（截屏回填 / 译文写入）时尽量保留插入点，避免光标乱跳
            let previousSelection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(previousSelection.location, text.utf16.count), length: 0))
        }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        Self.applyTypography(to: textView)

        if context.coordinator.shouldAutoFocus, !context.coordinator.didAutoFocus {
            context.coordinator.didAutoFocus = true
            let target = textView
            DispatchQueue.main.async {
                target.window?.makeFirstResponder(target)
            }
        }
    }

    private static func applyTypography(to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraph,
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var shouldAutoFocus = false
        var didAutoFocus = false

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            textView.needsDisplay = true      // 空/非空切换时刷新占位符
        }
    }
}
