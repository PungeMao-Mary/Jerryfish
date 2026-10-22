import AppKit
import Observation
import SwiftUI

// ============================================================
// 选区截屏翻译（有道式交互）
//
// 交互流程：
//   1. ⌘⇧A / 主界面「截屏」按钮 → 全屏**实时透明**遮罩（不冻结画面）；
//   2. 拖动框选 → 松开鼠标**不退出**，立即对选区 OCR + 分段翻译；
//   3. 译文**就地覆盖**原文：每个段落用纯色底盖住英文，中文画在框内；
//   4. 选区旁浮出胶囊操作条：完成 / 复制译文 / 重译 / 重新框选 / 显示原文 / 取消；
//   5. 只有「完成」或「取消」才退出截屏态（Esc 等同取消）。
//
// 关键实现：
//   - 遮罩使用 `[.borderless, .nonactivatingPanel]` + `orderFrontRegardless()`：
//     可成为 key（Esc / 十字准星）但**不激活本应用**，不抢用户焦点；
//   - `sharingType = .none` + 把本应用全部窗口号交给 ScreenCaptureKit 排除：
//     蒙层与译文层绝不会被拍进截图；
//   - 遮罩只呈现选区与译文层，**不做任何排版迭代**，保证延时可控。
// ============================================================

// MARK: - 就地译文块

/// 一个段落的中文译文及其在屏幕上的落点（面板局部坐标，单位：屏幕点）。
struct CaptureTranslationBlock: Identifiable, Equatable {
    let id: UUID
    var rect: CGRect
    var text: String
    var fontSize: CGFloat
    var lineCount: Int

    init(id: UUID = UUID(), rect: CGRect, text: String, fontSize: CGFloat, lineCount: Int = 1) {
        self.id = id
        self.rect = rect
        self.text = text
        self.fontSize = fontSize
        self.lineCount = lineCount
    }
}

// MARK: - 会话模型

/// 一次截屏翻译会话的完整状态（遮罩存活期间一直存在）。
@Observable
@MainActor
final class CaptureSessionModel {

    enum Phase: Equatable {
        case selecting
        case working(String)
        case ready
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    var phase: Phase = .selecting
    /// 选区（面板局部坐标，原点左上）
    var selectionRect: CGRect?
    /// 就地译文块
    var blocks: [CaptureTranslationBlock] = []
    /// 是否显示原文（默认 false：纯色底盖住英文）
    var showsOriginal = false
    var sourceText = ""
    var translatedText = ""
    /// 失败原因是「缺离线语言包」时给出下载入口
    var needsLanguagePack = false
    /// 「已复制」轻提示
    var copyFeedback = false
    /// 首次使用才显示拖拽提示
    var hintVisible = false
    /// 当前屏幕上可点选的窗口（面板局部坐标，每 0.5s 刷新）
    var windowCandidates: [CaptureWindowCandidate] = []
    /// 鼠标当前悬停的窗口（用于高亮预览）
    var hoveredWindow: CaptureWindowCandidate?
    /// 是否正在拖动框选（拖动时不显示窗口高亮）
    var isDragging = false

    var hasSelection: Bool { selectionRect != nil }
    var hasResult: Bool { !blocks.isEmpty }
    var isWorking: Bool { phase.isWorking }
    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }
    var progressText: String? {
        if case .working(let text) = phase { return text }
        return nil
    }
}

// MARK: - 动作回调

struct CaptureOverlayActions {
    /// 框选完成（参数为面板局部坐标）
    var commitSelection: (CGRect) -> Void
    var retranslate: () -> Void
    var copyTranslation: () -> Void
    var downloadLanguagePack: () -> Void
    var finish: () -> Void
    var cancel: () -> Void
}

// MARK: - 控制器

@MainActor
final class CaptureOverlayController {

    let session = CaptureSessionModel()

    /// 请求翻译（已经换算成 CG 全局点坐标 + 需要排除的窗口号 + 面板局部坐标）
    var onTranslateRequest: ((_ globalRect: CGRect, _ panelRect: CGRect, _ excluded: Set<Int>) -> Void)?
    var onCopy: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDownloadLanguagePack: (() -> Void)?

    /// 常驻翻译只借用截屏遮罩选择位置；松开鼠标后立刻撤掉遮罩并交还前台应用。
    var selectionOnly = false
    var onRegionSelected: ((_ globalRect: CGRect) -> Void)?

    private var panel: OverlayPanel?
    private var unionFrame: NSRect?
    private var didFinish = false
    private var windowRefreshTimer: Timer?
    /// 进入截屏时被临时移出屏幕的本应用窗口（截屏结束原样恢复）
    private var hiddenWindows: [(window: NSWindow, frame: NSRect, ignoresMouse: Bool, alpha: CGFloat)] = []
    /// 进入截屏前的前台应用（取消时归还焦点）
    private var previousFrontmost: NSRunningApplication?

    /// 呈现遮罩，进入截屏态。
    func present() {
        guard panel == nil, let union = Self.screenUnionFrame() else { return }
        unionFrame = union
        didFinish = false

        let panel = OverlayPanel(
            contentRect: union,
            // .nonactivatingPanel：成为 key 但不激活本应用，不抢用户焦点
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // 遮罩自身永远不会被任何截屏 API 拍到（兜底路径也安全）
        panel.sharingType = .none
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onCommit = { [weak self] in self?.finish() }
        panel.onCopy = { [weak self] in self?.onCopy?() }
        panel.onRetranslate = { [weak self] in self?.retranslate() }

        let actions = CaptureOverlayActions(
            commitSelection: { [weak self] rect in
                self?.commit(panelRect: rect)
            },
            retranslate: { [weak self] in self?.retranslate() },
            copyTranslation: { [weak self] in self?.onCopy?() },
            downloadLanguagePack: { [weak self] in self?.onDownloadLanguagePack?() },
            finish: { [weak self] in self?.finish() },
            cancel: { [weak self] in self?.cancel() }
        )
        let hosting = NSHostingView(rootView: CaptureOverlayView(session: session, actions: actions))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // 记住当前前台应用，取消截屏时归还焦点
        previousFrontmost = NSWorkspace.shared.frontmostApplication

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        // 把本应用自己的窗口移出屏幕，避免遮住用户要翻译的内容；
        // 之后显式激活本应用，保证遮罩能拿到 Esc / Enter 等键盘事件。
        hideOwnWindows()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        // 窗口点选支持：进入时枚举一次，之后每 0.5s 刷新（窗口可能被移动/关闭）
        refreshWindowCandidates()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWindowCandidates()
            }
        }
        windowRefreshTimer = timer
    }

    /// 重新枚举鼠标所在屏幕的窗口（排除本应用自身），供「点一下自动框选该窗口」使用。
    private func refreshWindowCandidates() {
        guard let union = unionFrame, panel != nil else { return }
        let panelOrigin = CGPoint(
            x: union.minX,
            y: ScreenGeometry.primaryDisplayHeight - union.maxY
        )
        // 本应用自身窗口（含遮罩）绝不参与点选
        let ownPIDs = Set([ProcessInfo.processInfo.processIdentifier])
        let candidates = CaptureWindowSnapper.candidates(
            panelOrigin: panelOrigin,
            excludingPIDs: ownPIDs
        )
        // 会话结束后仍可能有一次回调，做一次轻量保护
        if candidates != session.windowCandidates {
            session.windowCandidates = candidates
        }
        if let hovered = session.hoveredWindow,
           !candidates.contains(where: { $0.id == hovered.id }) {
            session.hoveredWindow = nil
        }
    }

    /// 把本应用的普通窗口（主窗口 / PDF 窗口）**真正隐藏**（alpha = 0，位置与尺寸都不动）。
    ///
    /// 踩过的两个坑：
    /// * `orderOut` / `alphaValue = 0` 会让 AppKit 认为本应用「没有可见窗口」→ 应用被取消激活
    ///   → 遮罩失去键盘焦点，Esc / Enter 失效。**对策**：隐藏之后显式
    ///   `NSApp.activate` 再 `panel.makeKey()`（见 present()），焦点就稳了。
    /// * 之前用「折叠成 1×1 挪到左下角」规避焦点问题，但会在左下角留一个小点（用户可见）。
    ///   alpha = 0 才是真正的隐藏，且不会残留任何像素。
    private func hideOwnWindows() {
        guard hiddenWindows.isEmpty else { return }
        for window in NSApp.windows where window.level == .normal && window.isVisible && window !== panel {
            hiddenWindows.append((window, window.frame, window.ignoresMouseEvents, window.alphaValue))
            window.ignoresMouseEvents = true
            window.alphaValue = 0
        }
    }

    /// 恢复被隐藏的窗口。
    private func restoreOwnWindows() {
        for item in hiddenWindows {
            item.window.ignoresMouseEvents = item.ignoresMouse
            item.window.alphaValue = item.alpha
            item.window.setFrame(item.frame, display: false)
        }
        hiddenWindows.removeAll()
    }

    /// 退出截屏态（不再回调）。
    func dismiss() {
        restoreOwnWindows()
        windowRefreshTimer?.invalidate()
        windowRefreshTimer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// 用当前选区重新翻译。
    func retranslate() {
        guard let rect = session.selectionRect else { return }
        commit(panelRect: rect)
    }

    // MARK: 内部

    private func commit(panelRect: CGRect) {
        guard let union = unionFrame else { return }
        let globalRect = globalRect(fromViewRect: panelRect, panelFrame: union)
        if selectionOnly {
            guard !didFinish else { return }
            didFinish = true
            dismiss()
            if let previous = previousFrontmost,
               previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous.activate(options: [])
            }
            let callback = onRegionSelected
            DispatchQueue.main.async { callback?(globalRect) }
            return
        }
        onTranslateRequest?(globalRect, panelRect, Self.ownWindowNumbers())
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        dismiss()
        let callback = onFinish
        DispatchQueue.main.async { callback?() }
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        dismiss()
        let callback = onCancel
        // 把焦点还给用户原来的应用（取消 = 什么都没发生）
        if let previous = previousFrontmost, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous.activate(options: [])
        }
        DispatchQueue.main.async { callback?() }
    }

    /// 所有屏幕的并集（NSScreen 坐标：主屏左下为原点）。
    private static func screenUnionFrame() -> NSRect? {
        let screens = NSScreen.screens
        guard let first = screens.first else { return nil }
        return screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    /// 面板内视图坐标（左上原点）→ CG 全局点坐标（左上原点）。
    private func globalRect(fromViewRect rect: CGRect, panelFrame: NSRect) -> CGRect {
        let height = ScreenGeometry.primaryDisplayHeight
        return CGRect(
            x: panelFrame.minX + rect.minX,
            y: height - panelFrame.maxY + rect.minY,
            width: rect.width,
            height: rect.height
        ).standardized
    }

    /// 本应用自身的全部窗口号：从截屏内容中排除，防止遮罩或主窗口挡住被翻译的文献。
    private static func ownWindowNumbers() -> Set<Int> {
        Set(NSApp.windows.map(\.windowNumber).filter { $0 > 0 })
    }
}

// MARK: - 面板

/// 无边框遮罩面板：可成为 key（用于接收 Esc），但不激活本应用。
final class OverlayPanel: NSPanel {

    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRetranslate: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let isCommand = event.modifierFlags.contains(.command)
        // ESC / ⌘. 取消
        if event.keyCode == 53 || (isCommand && event.charactersIgnoringModifiers == ".") {
            onCancel?()
            return
        }
        // Return / Enter：完成（退出截屏并把结果交回主界面）
        if event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        // ⌘C：复制译文
        if isCommand, event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopy?()
            return
        }
        // ⌘R：重译
        if isCommand, event.charactersIgnoringModifiers?.lowercased() == "r" {
            onRetranslate?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }
}

// MARK: - 蒙层与译文渲染

struct CaptureOverlayView: View {

    @Bindable var session: CaptureSessionModel
    let actions: CaptureOverlayActions

    @State private var dragOrigin: CGPoint?

    private let dimOpacity: Double = 0.32
    private let accent = Color(red: 0.10, green: 0.62, blue: 0.98)
    /// 译文覆盖层：纯色底（不透明到足以完全遮住英文）
    private let coverFill = Color(red: 0.11, green: 0.11, blue: 0.125).opacity(0.96)
    private let barHeight: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                dimmingLayer(size: size)

                // 悬停窗口高亮（拖动中或已有选区时不显示）
                if !session.isDragging, !session.hasSelection, let hovered = session.hoveredWindow {
                    windowHighlight(hovered)
                }

                if let rect = session.selectionRect {
                    selectionDecoration(rect)
                    if session.hasSelection {
                        sizeBadge(rect: rect, viewSize: size)
                    }
                } else if session.hintVisible {
                    hint
                        .position(x: size.width / 2, y: size.height / 2)
                        .allowsHitTesting(false)
                }

                // 就地译文（默认纯色底盖住英文）
                if !session.showsOriginal {
                    ForEach(session.blocks) { block in
                        translationBlock(block)
                    }
                }

                if session.hasSelection {
                    controlBar(viewSize: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(viewSize: size))
            .onContinuousHover { phase in
                handleHover(phase, viewSize: size)
            }
            // 单击 = 点选鼠标下方的窗口（整窗翻译）；拖动 = 自由框选
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                selectWindow(at: location)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 蒙层

    /// 四块矩形拼出「中间挖空」的暗色蒙层；背景保持实时透明（不冻结画面）。
    private func dimmingLayer(size: CGSize) -> some View {
        let full = CGRect(origin: .zero, size: size)
        let hole = (session.selectionRect ?? .zero).intersection(full).standardized
        let shade = Color.black.opacity(dimOpacity)

        return ZStack(alignment: .topLeading) {
            if hole.isNull || hole.width < 1 || hole.height < 1 {
                Rectangle().fill(shade)
                    .frame(width: size.width, height: size.height)
            } else {
                Rectangle().fill(shade)
                    .frame(width: size.width, height: max(0, hole.minY))
                Rectangle().fill(shade)
                    .frame(width: size.width, height: max(0, size.height - hole.maxY))
                    .offset(x: 0, y: hole.maxY)
                Rectangle().fill(shade)
                    .frame(width: max(0, hole.minX), height: max(0, hole.height))
                    .offset(x: 0, y: hole.minY)
                Rectangle().fill(shade)
                    .frame(width: max(0, size.width - hole.maxX), height: max(0, hole.height))
                    .offset(x: hole.maxX, y: hole.minY)
            }
        }
    }

    private func selectionDecoration(_ rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(accent, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)

            ForEach(cornerPoints(in: rect), id: \.self) { point in
                Rectangle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .offset(x: point.x - 3, y: point.y - 3)
            }
        }
        .allowsHitTesting(false)
    }

    /// 悬停窗口：淡色填充 + 边框 + 应用名尺寸标签，明确「点一下就是它」。
    private func windowHighlight(_ window: CaptureWindowCandidate) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(accent.opacity(0.14))
                .frame(width: window.bounds.width, height: window.bounds.height)
                .offset(x: window.bounds.minX, y: window.bounds.minY)

            Rectangle()
                .strokeBorder(accent.opacity(0.9), lineWidth: 2)
                .frame(width: window.bounds.width, height: window.bounds.height)
                .offset(x: window.bounds.minX, y: window.bounds.minY)

            Text("\(window.ownerName)  ·  \(Int(window.bounds.width)) × \(Int(window.bounds.height))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(accent.opacity(0.92)))
                .offset(x: window.bounds.minX + 6,
                        y: max(0, window.bounds.minY + 6))
        }
        .allowsHitTesting(false)
    }

    /// 鼠标移动：更新悬停窗口（拖动与已有选区时不参与）。
    private func handleHover(_ phase: HoverPhase, viewSize: CGSize) {
        switch phase {
        case .active(let location):
            NSCursor.crosshair.set()
            guard !session.isDragging, !session.hasSelection else {
                if session.hoveredWindow != nil { session.hoveredWindow = nil }
                return
            }
            let hit = CaptureWindowSnapper.hitTest(location, in: session.windowCandidates)
            if hit?.id != session.hoveredWindow?.id {
                session.hoveredWindow = hit
            }
        case .ended:
            session.hoveredWindow = nil
        }
    }

    /// 点击：把鼠标下方窗口整块作为选区并立即翻译。
    private func selectWindow(at location: CGPoint) {
        guard !session.hasSelection, !session.isWorking else { return }
        // 优先选面积最小的那个：点小窗口不会被盖住它的大窗口抢走
        guard let hit = CaptureWindowSnapper.hitTestPreferringSmallest(
            location, in: session.windowCandidates
        ) else { return }
        session.hoveredWindow = nil
        session.selectionRect = hit.bounds
        actions.commitSelection(hit.bounds)
    }

    private func cornerPoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    // MARK: 译文块

    private func translationBlock(_ block: CaptureTranslationBlock) -> some View {
        let available = max(1, block.rect.width - 6)
        let lines = max(1, block.lineCount)
        return Text(block.text)
            .font(.system(size: block.fontSize))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineSpacing(1)
            .lineLimit(lines + 1)
            .minimumScaleFactor(0.7)
            .frame(width: available, height: max(1, block.rect.height - 3), alignment: .topLeading)
            .padding(.horizontal, 3)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(coverFill)
            )
            .position(x: block.rect.midX, y: block.rect.midY)
            .allowsHitTesting(false)
    }

    // MARK: 尺寸提示

    private func sizeBadge(rect: CGRect, viewSize: CGSize) -> some View {
        Text("\(Int(rect.width)) × \(Int(rect.height))")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .position(
                x: min(max(rect.minX + 44, 46), max(46, viewSize.width - 46)),
                y: rect.minY > 24 ? rect.minY - 15 : min(rect.maxY + 15, viewSize.height - 14)
            )
            .allowsHitTesting(false)
    }

    private var hint: some View {
        VStack(spacing: 8) {
            Image(systemName: "viewfinder")
                .font(.system(size: 30, weight: .light))
            Text(String(localized: "框选需要翻译的文字区域"))
                .font(.system(size: 15, weight: .medium))
            Text(String(localized: "点击窗口 = 整窗翻译 · 拖动 = 自由框选 · Esc 取消"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
    }

    // MARK: 操作条

    private func controlBar(viewSize: CGSize) -> some View {
        let rect = session.selectionRect ?? .zero
        let barWidth = barWidth()
        let x = min(max(rect.midX, barWidth / 2 + 6), max(barWidth / 2 + 6, viewSize.width - barWidth / 2 - 6))
        let below = rect.maxY + 14
        let fitsBelow = below + barHeight <= viewSize.height - 8
        let y = fitsBelow ? below : max(8 + barHeight / 2, rect.minY - 14 - barHeight / 2)

        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                if let progress = session.progressText {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 16)
                    Text(progress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    barSeparator
                } else if let error = session.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .leading)
                    if session.needsLanguagePack {
                        barButton(icon: "arrow.down.circle", help: String(localized: "下载离线语言包")) {
                            actions.downloadLanguagePack()
                        }
                    }
                    barSeparator
                } else if session.copyFeedback {
                    barButton(icon: "checkmark.circle.fill",
                              help: String(localized: "已复制"),
                              tint: .green) {}
                    Text(String(localized: "已复制")).font(.system(size: 11)).foregroundStyle(.secondary)
                    barSeparator
                }

                // ✓ 完成
                barButton(icon: "checkmark",
                          help: String(localized: "完成（退出截屏，Enter）"),
                          enabled: session.hasResult || !session.isWorking,
                          tint: session.hasResult ? .green : .primary) {
                    actions.finish()
                }
                // 复制译文
                barButton(icon: "doc.on.doc",
                          help: String(localized: "复制译文（⌘C）"),
                          enabled: !session.translatedText.isEmpty) {
                    actions.copyTranslation()
                }
                // 重译
                barButton(icon: "arrow.clockwise",
                          help: String(localized: "重新翻译（⌘R）"),
                          enabled: session.hasSelection && !session.isWorking) {
                    actions.retranslate()
                }
                // 重新框选区域
                barButton(icon: "viewfinder",
                          help: String(localized: "重新框选区域"),
                          enabled: !session.isWorking) {
                    beginReselect()
                }
                // 显示原文 / 显示译文
                barButton(icon: session.showsOriginal ? "eye.slash" : "eye",
                          help: session.showsOriginal
                              ? String(localized: "遮盖原文（显示译文）")
                              : String(localized: "显示原文") ,
                          enabled: session.hasResult) {
                    session.showsOriginal.toggle()
                }
                // 取消
                barButton(icon: "xmark",
                          help: String(localized: "取消（Esc）")) {
                    actions.cancel()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        Capsule(style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
            )
        }
        .fixedSize()
        .position(x: x, y: y)
    }

    private var barSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func barWidth() -> CGFloat {
        if session.errorMessage != nil { return 420 }
        if session.progressText != nil { return 220 }
        return 6 * 30 + 20
    }

    private func barButton(
        icon: String,
        help: String,
        enabled: Bool = true,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.45))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }

    private func beginReselect() {
        session.blocks = []
        session.selectionRect = nil
        session.sourceText = ""
        session.translatedText = ""
        session.showsOriginal = false
        session.needsLanguagePack = false
        session.phase = .selecting
    }

    // MARK: 手势

    private func dragGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = value.startLocation
                    session.isDragging = true
                    session.hoveredWindow = nil
                    // 开始新的框选：清掉上一次的译文
                    if session.hasResult { beginReselect() }
                }
                guard let origin = dragOrigin else { return }
                session.selectionRect = Self.normalizedRect(from: origin, to: value.location, bounds: viewSize)
            }
            .onEnded { value in
                defer {
                    dragOrigin = nil
                    session.isDragging = false
                }
                guard let origin = dragOrigin else { return }
                let rect = Self.normalizedRect(from: origin, to: value.location, bounds: viewSize)
                session.selectionRect = rect
                guard rect.width >= ScreenCaptureService.minimumSelectionSide,
                      rect.height >= ScreenCaptureService.minimumSelectionSide else {
                    session.selectionRect = nil
                    return
                }
                actions.commitSelection(rect)
            }
    }

    static func normalizedRect(from a: CGPoint, to b: CGPoint, bounds: CGSize) -> CGRect {
        let rect = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
        let clamped = rect.intersection(CGRect(origin: .zero, size: bounds))
        return clamped.isNull ? .zero : clamped
    }
}

// MARK: - 归一化包围盒 → 就地译文块

enum CaptureBlockLayout {

    /// 把 OCR 段落块映射成屏幕上的纯色覆盖块。
    ///
    /// 刻意「不做排版迭代」：字号由行高一次性推算并夹紧，最多再等比缩小一次，
    /// 保证这部分耗时是 O(块数) 且可忽略。
    static func makeBlocks(
        ocr: OCRResult,
        translations: [String],
        selection: CGRect,
        minimumFontSize: CGFloat = 9,
        maximumFontSize: CGFloat = 16
    ) -> [CaptureTranslationBlock] {
        guard !ocr.blocks.isEmpty, selection.width > 1, selection.height > 1 else { return [] }

        var result: [CaptureTranslationBlock] = []
        result.reserveCapacity(ocr.blocks.count)

        for (index, block) in ocr.blocks.enumerated() {
            guard index < translations.count else { break }
            let translated = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { continue }

            // 归一化 → 面板局部坐标（两块都是原点左上，且捕获图与选区一一对应）
            let normalized = block.boundingBox
            let box = CGRect(
                x: selection.minX + normalized.minX * selection.width,
                y: selection.minY + normalized.minY * selection.height,
                width: max(4, normalized.width * selection.width),
                height: max(4, normalized.height * selection.height)
            )
            // 稍微外扩，确保完全遮住原文（OCR 框通常偏紧）
            let cover = box.insetBy(dx: -2, dy: -1.5)

            let lines = max(1, block.lineCount)
            var font = min(maximumFontSize, max(minimumFontSize, cover.height / CGFloat(lines) * 0.92))
            let availableWidth = max(8, cover.width - 6)
            var neededLines = estimatedLines(characters: translated.count,
                                            availableWidth: availableWidth,
                                            font: font)
            let neededHeight = CGFloat(neededLines) * font * 1.22 + 3
            if neededHeight > cover.height + 1 {
                // 一次性等比缩小，不做迭代收敛
                font = max(minimumFontSize * 0.8, font * (cover.height / neededHeight))
                neededLines = estimatedLines(characters: translated.count,
                                             availableWidth: availableWidth,
                                             font: font)
            }

            result.append(CaptureTranslationBlock(
                rect: cover,
                text: translated,
                fontSize: font,
                lineCount: min(neededLines, lines + 2)
            ))
        }
        return result
    }

    /// CJK 近似按 1em 宽估算每行容量（延时敏感，允许近似）。
    static func estimatedLines(characters: Int, availableWidth: CGFloat, font: CGFloat) -> Int {
        guard font > 0, availableWidth > 0 else { return 1 }
        let perLine = max(1, Int(availableWidth / font))
        return max(1, Int(ceil(Double(characters) / Double(perLine))))
    }
}
