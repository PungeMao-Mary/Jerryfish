#if os(macOS)
#if canImport(AppKit)
import AppKit
#else
// iOS：AppKit 的等价类型在本模块的 AppKitCompatIOS.swift 中映射；
// 这里补上原来由 AppKit 顺带带入的 Foundation / CoreGraphics / UIKit。
import Foundation
internal import CoreGraphics
import UIKit
#endif
import PDFKit

// ============================================================
// PDF 画布：自绘 PDF 页面 + 批注，并处理全部鼠标交互。
//
// 采用「自绘 + 归一化坐标」而非 PDFKit 原生 Annotation，原因：
//  - PDF 文件全程只读，绝不写回；
//  - 批注是纯内存数据，配合 UndoManager 快照即可完美撤销/重做；
//  - 完全掌控外观（颜色、粗细、半透明高亮、文字框）。
// ============================================================

@MainActor
final class PDFCanvasView: NSView, NSTextFieldDelegate, NSUserInterfaceValidations {

    // 由 SwiftUI 注入
    var pdfDocument: PDFDocument? {
        didSet {
            thumbnailCache.removeAll()
            updateFrameSize()
            needsDisplay = true
        }
    }
    var items: [PDFAnnotationItem] = [] { didSet { needsDisplay = true } }
    var tool: PDFReaderTool = .cursor {
        didSet {
            needsDisplay = true
            if tool != oldValue { refreshCursorState() }
        }
    }
    var colorHex: String = "#E64B35"
    var lineWidth: CGFloat = 3
    var fontSize: CGFloat = 18
    var selectedItemID: UUID? { didSet { needsDisplay = true } }

    var zoom: CGFloat = 1 {
        didSet {
            guard abs(zoom - oldValue) > 0.0001 else { return }
            // 【性能节约模式】缓存按页面（与缩放无关），缩放时无需清空重渲
            if !performanceSaverMode { thumbnailCache.removeAll() }
            updateFrameSize()
            needsDisplay = true
        }
    }

    var onCommit: (([PDFAnnotationItem], String) -> Void)?
    var onSelect: ((UUID?) -> Void)?

    // ==========================================================
    // 【新增·可选】用鼠标工具选中并复制 PDF 原文（原生 PDFKit 文本层）
    //
    // 关闭时（false）行为与原实现完全一致。
    // 打开后：.cursor 工具在「未命中任何已有批注」时，拖动即为选择文本，
    // 与原生 PDFKit 一样按阅读顺序选中，⌘C 复制、⌘A 全选。
    // ==========================================================
    var textSelectionEnabled: Bool = true {
        didSet { if textSelectionEnabled != oldValue { refreshCursorState() } }
    }
    var onTextSelectionChanged: ((String?) -> Void)?

    private var textSelection: PDFSelection?
    private var textSelectionAnchor: CGPoint?
    private var isSelectingText = false
    private var lastCursorProbePoint: CGPoint?
    private var hoverTrackingArea: NSTrackingArea?

    /// 当前选中的原文（供宿主显示/复制）
    var selectedText: String? { textSelection?.string }
    /// 双指捏合（妙控板）改变缩放时回调，用于同步 SwiftUI 的缩放条/百分比
    var onZoomChanged: ((CGFloat) -> Void)?

    // MARK: 几何常量
    private let pageMargin: CGFloat = 24
    private let pageGap: CGFloat = 18

    private struct PageLayout {
        let index: Int
        let rect: CGRect
        let pageSize: CGSize
    }

    private var thumbnailCache: [String: NSImage] = [:]

    // ==========================================================
    // 【性能节约模式】由 SwiftUI 注入（设置 → UI，默认关闭）。
    // 开启后：页面以低分辨率渲染（长边 ≤ saverMaxDimension），并按“页”缓存，
    // 缩放时直接拉伸复用位图，不再重新光栅化密集矢量内容。
    // ==========================================================
    var performanceSaverMode: Bool = false {
        didSet {
            guard performanceSaverMode != oldValue else { return }
            thumbnailCache.removeAll()
            needsDisplay = true
        }
    }

    /// 性能节约模式下的最大渲染边长（pt）
    private static let saverMaxDimension: CGFloat = 512

    // MARK: 交互状态
    private enum Handle { case topLeft, topRight, bottomLeft, bottomRight
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }
    private enum Interaction {
        case none
        case drawing(draftIndex: Int)
        case moving(id: UUID, original: PDFAnnotationItem, startView: CGPoint)
        case resizing(id: UUID, original: PDFAnnotationItem, handle: Handle)
    }

    private var interaction: Interaction = .none
    private var draft: PDFAnnotationItem?
    private var penPoints: [CGPoint] = []

    // 文本编辑
    private var editingItemID: UUID?
    private var editingField: NSTextField?
    private var editingIsNew = false

    // MARK: - 视图基础

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFrameSize()
        observeClipView()
        installHoverTracking()
        thumbnailCache.removeAll()
    }

    /// 安装悬停跟踪区：mouseMoved 才会被派发到本视图（用于 I 形光标）
    private func installHoverTracking() {
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        window?.acceptsMouseMovedEvents = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private var clipObserver: NSObjectProtocol?

    /// 监听裁剪视图尺寸变化 → 重算画布宽度，保证页面始终水平居中
    private func observeClipView() {
        if let token = clipObserver { NotificationCenter.default.removeObserver(token) }
        clipObserver = nil
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            // queue: .main 保证在主线程回调；此处显式声明隔离，满足 Swift 6 并发检查。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateFrameSize()
                self.needsDisplay = true
            }
        }
    }

    deinit {
        if let token = clipObserver { NotificationCenter.default.removeObserver(token) }
    }

    /// 每页的缩放后尺寸与原页点尺寸
    private func scaledPages() -> [(index: Int, size: CGSize, pageSize: CGSize)] {
        guard let doc = pdfDocument else { return [] }
        return (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let ps = page.bounds(for: .cropBox).size
            return (i, CGSize(width: max(1, ps.width * zoom), height: max(1, ps.height * zoom)), ps)
        }
    }

    /// 内容总尺寸（含页边距，且至少和视口一样宽，便于水平居中）
    func contentSize() -> NSSize {
        let pages = scaledPages()
        guard !pages.isEmpty else { return NSSize(width: 600, height: 400) }
        let maxW = pages.map { $0.size.width }.max() ?? 600
        let totalH = pages.reduce(0) { $0 + $1.size.height } + CGFloat(max(0, pages.count - 1)) * pageGap
        let viewportW = enclosingScrollView?.contentView.bounds.width ?? 0
        return NSSize(width: max(maxW + pageMargin * 2, viewportW), height: totalH + pageMargin * 2)
    }

    func updateFrameSize() {
        let size = contentSize()
        if frame.size != size {
            setFrameSize(size)
        }
    }

    private func computeLayouts() -> [PageLayout] {
        let pages = scaledPages()
        var result: [PageLayout] = []
        var y = pageMargin
        for p in pages {
            let x = max(pageMargin, (frame.width - p.size.width) / 2)
            result.append(PageLayout(index: p.index, rect: CGRect(x: x, y: y, width: p.size.width, height: p.size.height), pageSize: p.pageSize))
            y += p.size.height + pageGap
        }
        return result
    }

    private func layout(forPage index: Int, in layouts: [PageLayout]) -> PageLayout? {
        layouts.first { $0.index == index }
    }

    private func viewPoint(_ p: CGPoint, in layout: PageLayout) -> CGPoint {
        CGPoint(x: layout.rect.minX + p.x * layout.rect.width,
                y: layout.rect.minY + p.y * layout.rect.height)
    }

    private func normalizedPoint(_ p: CGPoint, in layout: PageLayout) -> CGPoint {
        CGPoint(x: (p.x - layout.rect.minX) / max(1, layout.rect.width),
                y: (p.y - layout.rect.minY) / max(1, layout.rect.height))
    }

    private func viewRect(for item: PDFAnnotationItem, layouts: [PageLayout]) -> CGRect? {
        guard let layout = layout(forPage: item.pageIndex, in: layouts) else { return nil }
        let b = item.normalizedBounds
        return CGRect(x: layout.rect.minX + b.minX * layout.rect.width,
                      y: layout.rect.minY + b.minY * layout.rect.height,
                      width: b.width * layout.rect.width,
                      height: b.height * layout.rect.height)
    }

    /// 渲染倍率覆盖（仅供测试注入；正常为 nil）
    var renderScaleOverride: CGFloat?

    /// 当前窗口的 backing scale（Retina 屏为 2）
    private var renderScale: CGFloat {
        if let override = renderScaleOverride { return max(1, override) }
        return max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    private func thumbnail(for layout: PageLayout) -> NSImage? {
        guard let page = pdfDocument?.page(at: layout.index) else { return nil }

        // 【修复发虚】必须按 backing scale 请求**像素**尺寸：
        // 只按「点」尺寸渲染时，Retina 屏上拿到的是 1x 位图，
        // 铺到 2x 屏幕上就是被放大的模糊图（这正是「不如空格 Quick Look 清晰」的原因）。
        let scale = renderScale
        let key: String
        let pixelSize: CGSize
        if performanceSaverMode {
            // 与缩放无关：同一页只渲一次；像素数封顶，降低密集矢量图成本
            key = "saver|\(layout.index)@\(scale)"
            let pageSize = page.bounds(for: .cropBox).size
            let longestPoints = max(1, max(pageSize.width, pageSize.height))
            let factor = min(1.0, Self.saverMaxDimension / longestPoints)
            pixelSize = CGSize(width: max(1, pageSize.width * factor * scale),
                               height: max(1, pageSize.height * factor * scale))
        } else {
            key = "\(layout.index)@\(Int(layout.rect.width))x\(Int(layout.rect.height))@\(scale)"
            pixelSize = CGSize(width: max(1, layout.rect.width * scale),
                               height: max(1, layout.rect.height * scale))
        }

        if let cached = thumbnailCache[key] { return cached }
        let image = page.thumbnail(of: pixelSize, for: .cropBox)
        thumbnailCache[key] = image
        return image
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        if let bg = NSColor(named: "PDFCanvasBackground") {
            bg.setFill()
        } else {
            NSColor.textBackgroundColor.setFill()
        }
        dirtyRect.fill()

        let layouts = computeLayouts()
        for layout in layouts where layout.rect.intersects(dirtyRect) {
            NSColor.black.withAlphaComponent(0.10).setFill()
            NSBezierPath(rect: layout.rect.offsetBy(dx: 0, dy: 1.5)).fill()

            NSColor.white.setFill()
            layout.rect.fill()

            if let image = thumbnail(for: layout) {
                image.draw(in: layout.rect)
            }

            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(rect: layout.rect)
            border.lineWidth = 1
            border.stroke()
        }

        for item in items { draw(item, layouts: layouts) }
        if let draft { draw(draft, layouts: layouts) }
        // 【新增】原文选中高亮
        if let selection = textSelection { drawTextSelection(selection, layouts: layouts) }

        if tool == .cursor, let id = selectedItemID, let sel = items.first(where: { $0.id == id }) {
            drawSelection(sel, layouts: layouts)
        }
    }

    private func draw(_ item: PDFAnnotationItem, layouts: [PageLayout]) {
        guard let layout = layout(forPage: item.pageIndex, in: layouts) else { return }
        let color = item.color
        let lw = max(1, item.lineWidth * zoom)

        switch item.kind {
        case .rectangle, .ellipse:
            let r = viewRect(for: item, layouts: layouts) ?? .zero
            let path = item.kind == .rectangle ? NSBezierPath(rect: r) : NSBezierPath(ovalIn: r)
            path.lineWidth = lw
            color.setStroke()
            path.stroke()

        case .line:
            let path = NSBezierPath()
            path.move(to: viewPoint(item.start, in: layout))
            path.line(to: viewPoint(item.end, in: layout))
            path.lineWidth = lw
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()

        case .pen, .highlight:
            guard item.points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: viewPoint(item.points[0], in: layout))
            for p in item.points.dropFirst() { path.line(to: viewPoint(p, in: layout)) }
            path.lineWidth = item.kind == .highlight ? max(lw, 6 * zoom) : lw
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            (item.kind == .highlight ? color.withAlphaComponent(0.35) : color).setStroke()
            path.stroke()

        case .text:
            let r = viewRect(for: item, layouts: layouts) ?? .zero
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(6, item.fontSize * zoom)),
                .foregroundColor: color
            ]
            // 【新增】可选填充底色：译文批注用它盖住原文，避免中英重叠
            if let fill = item.fillColor {
                fill.setFill()
                NSBezierPath(rect: r).fill()
                // 有底色时把文字裁进框内，避免溢出到框外的原文上
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: r).addClip()
                (item.text as NSString).draw(in: r.insetBy(dx: 3, dy: 2), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                (item.text as NSString).draw(in: r.insetBy(dx: 1, dy: 1), withAttributes: attrs)
            }
        }
    }

    private func drawSelection(_ item: PDFAnnotationItem, layouts: [PageLayout]) {
        guard let r = viewRect(for: item, layouts: layouts) else { return }
        let path = NSBezierPath(rect: r.insetBy(dx: -3, dy: -3))
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        NSColor.controlAccentColor.setFill()
        for handle in [Handle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let p = handle.point(in: r)
            NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
        }
    }

    // MARK: - 命中测试

    private func polylineHit(_ item: PDFAnnotationItem, layout: PageLayout, point: CGPoint, tolerance: CGFloat) -> Bool {
        guard item.points.count > 1 else { return false }
        var previous = viewPoint(item.points[0], in: layout)
        for p in item.points.dropFirst() {
            let current = viewPoint(p, in: layout)
            if distanceToSegment(point, previous, current) <= tolerance { return true }
            previous = current
        }
        return false
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func hitItem(at point: CGPoint, layouts: [PageLayout]) -> PDFAnnotationItem? {
        for item in items.reversed() {
            guard let layout = layout(forPage: item.pageIndex, in: layouts) else { continue }
            if item.kind == .pen || item.kind == .highlight {
                if polylineHit(item, layout: layout, point: point, tolerance: 8) { return item }
            } else if let r = viewRect(for: item, layouts: layouts), r.insetBy(dx: -6, dy: -6).contains(point) {
                return item
            }
        }
        return nil
    }

    private func handleHit(at point: CGPoint, for item: PDFAnnotationItem, layouts: [PageLayout]) -> Handle? {
        guard let r = viewRect(for: item, layouts: layouts) else { return nil }
        for handle in [Handle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let p = handle.point(in: r)
            if hypot(point.x - p.x, point.y - p.y) <= 9 { return handle }
        }
        return nil
    }

    private func layoutAndPage(for point: CGPoint, layouts: [PageLayout]) -> (PageLayout, PDFPage)? {
        for layout in layouts where layout.rect.contains(point) {
            if let page = pdfDocument?.page(at: layout.index) { return (layout, page) }
        }
        return nil
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditingIfNeeded()

        let point = convert(event.locationInWindow, from: nil)
        let layouts = computeLayouts()
        guard let (layout, _) = layoutAndPage(for: point, layouts: layouts) else {
            interaction = .none
            onSelect?(nil)
            return
        }
        let normalized = normalizedPoint(point, in: layout)

        switch tool {
        case .cursor:
            if let id = selectedItemID, let sel = items.first(where: { $0.id == id }),
               let handle = handleHit(at: point, for: sel, layouts: layouts) {
                interaction = .resizing(id: id, original: sel, handle: handle)
                return
            }
            if let hit = hitItem(at: point, layouts: layouts) {
                onSelect?(hit.id)
                interaction = .moving(id: hit.id, original: hit, startView: point)
            } else if textSelectionEnabled {
                // 【新增】未命中批注 → 选择 PDF 原文
                isSelectingText = true
                textSelectionAnchor = point
                selectText(fromViewPoint: point, toViewPoint: point)
            } else {
                onSelect?(nil)
                interaction = .none
            }

        case .rectangle, .ellipse, .line:
            let item = PDFAnnotationItem(
                kind: tool == .rectangle ? .rectangle : (tool == .ellipse ? .ellipse : .line),
                pageIndex: layout.index, start: normalized, end: normalized,
                colorHex: colorHex, lineWidth: lineWidth
            )
            draft = item
            interaction = .drawing(draftIndex: layout.index)
            needsDisplay = true

        case .pen, .highlight:
            penPoints = [normalized]
            var item = PDFAnnotationItem(
                kind: tool == .pen ? .pen : .highlight,
                pageIndex: layout.index, start: normalized, end: normalized,
                points: penPoints, colorHex: colorHex,
                lineWidth: lineWidth
            )
            item.end = normalized
            draft = item
            interaction = .drawing(draftIndex: layout.index)
            needsDisplay = true

        case .text:
            if let hit = hitItem(at: point, layouts: layouts), hit.kind == .text {
                beginTextEditing(hit, in: layout)
            } else {
                let boxWidth: CGFloat = 0.32
                // fontSize 单位是页点，转成归一化高度要用页的真实高度
                let boxHeight = min(0.5, max(0.04, (fontSize * 1.6) / max(1, layout.pageSize.height)))
                let end = CGPoint(x: min(1, normalized.x + boxWidth), y: min(1, normalized.y + boxHeight))
                let item = PDFAnnotationItem(
                    kind: .text, pageIndex: layout.index,
                    start: normalized, end: end,
                    colorHex: colorHex, lineWidth: lineWidth, text: "", fontSize: fontSize
                )
                beginTextEditing(item, in: layout, isNew: true)
            }

        case .eraser:
            if let hit = hitItem(at: point, layouts: layouts) {
                let name = hit.kind == .text ? String(localized: "Erase Text") : String(localized: "Erase Annotation")
                onCommit?(items.filter { $0.id != hit.id }, name)
            }
        }
    }

    // MARK: - 【新增】悬停光标：移到可选文字上时变成 I 形

    override func mouseMoved(with event: NSEvent) {
        guard textSelectionEnabled, tool == .cursor, !isSelectingText else {
            NSCursor.arrow.set()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // 轻微去抖：位移不到 2pt 不重复做命中测试
        if let last = lastCursorProbePoint, hypot(point.x - last.x, point.y - last.y) < 2 { return }
        lastCursorProbePoint = point
        if isPointOverSelectableText(point) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        lastCursorProbePoint = nil
        NSCursor.arrow.set()
    }

    /// 工具/开关变化时让光标状态及时刷新
    private func refreshCursorState() {
        lastCursorProbePoint = nil
        window?.invalidateCursorRects(for: self)
        if !textSelectionEnabled || tool != .cursor { NSCursor.arrow.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layouts = computeLayouts()

        // 【新增】正在选择原文
        if isSelectingText, let anchor = textSelectionAnchor {
            selectText(fromViewPoint: anchor, toViewPoint: point)
            autoScrollIfNeeded(towards: point)
            return
        }

        switch interaction {
        case .drawing:
            guard var item = draft,
                  let layout = layout(forPage: item.pageIndex, in: layouts),
                  layout.rect.insetBy(dx: -40, dy: -40).contains(point) else { return }
            let normalized = normalizedPoint(point, in: layout)
            if item.kind == .pen || item.kind == .highlight {
                penPoints.append(normalized)
                item.points = penPoints
                item.end = normalized
            } else {
                var end = normalized
                if event.modifierFlags.contains(.shift) {
                    switch item.kind {
                    case .line:
                        end = abs(end.x - item.start.x) >= abs(end.y - item.start.y)
                            ? CGPoint(x: end.x, y: item.start.y)
                            : CGPoint(x: item.start.x, y: end.y)
                    default:
                        let dx = end.x - item.start.x, dy = end.y - item.start.y
                        let m = max(abs(dx), abs(dy))
                        end = CGPoint(x: item.start.x + (dx < 0 ? -m : m),
                                      y: item.start.y + (dy < 0 ? -m : m))
                    }
                }
                item.end = end
            }
            draft = item
            needsDisplay = true

        case .moving(let id, let original, let startView):
            guard let layout = layout(forPage: original.pageIndex, in: layouts) else { return }
            let dx = (point.x - startView.x) / max(1, layout.rect.width)
            let dy = (point.y - startView.y) / max(1, layout.rect.height)
            var moved = original
            moved.translate(dx: dx, dy: dy)
            applyLive(moved, id: id)

        case .resizing(let id, let original, let handle):
            guard let layout = layout(forPage: original.pageIndex, in: layouts) else { return }
            let norm = normalizedPoint(point, in: layout)
            var bounds = original.normalizedBounds
            switch handle {
            case .topLeft: bounds = CGRect(x: norm.x, y: norm.y, width: bounds.maxX - norm.x, height: bounds.maxY - norm.y)
            case .topRight: bounds = CGRect(x: bounds.minX, y: norm.y, width: norm.x - bounds.minX, height: bounds.maxY - norm.y)
            case .bottomLeft: bounds = CGRect(x: norm.x, y: bounds.minY, width: bounds.maxX - norm.x, height: norm.y - bounds.minY)
            case .bottomRight: bounds = CGRect(x: bounds.minX, y: bounds.minY, width: norm.x - bounds.minX, height: norm.y - bounds.minY)
            }
            guard bounds.width > 0.005, bounds.height > 0.005 else { return }
            var resized = original
            resized.remap(from: original.normalizedBounds, to: bounds)
            applyLive(resized, id: id)

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 【新增】结束原文选择
        if isSelectingText {
            isSelectingText = false
            textSelectionAnchor = nil
            onTextSelectionChanged?(textSelection?.string)
            needsDisplay = true
            return
        }

        switch interaction {
        case .drawing:
            if let item = draft {
                let name: String
                switch item.kind {
                case .rectangle: name = String(localized: "Add Rectangle")
                case .ellipse: name = String(localized: "Add Ellipse")
                case .pen: name = String(localized: "Add Drawing")
                case .line: name = String(localized: "Add Line")
                case .highlight: name = String(localized: "Add Highlight")
                case .text: name = String(localized: "Add Text")
                }
                var next = items
                next.append(item)
                onCommit?(next, name)
                onSelect?(item.id)
            }
            draft = nil
            penPoints = []

        case .moving:
            // applyLive 已把当前数组就地更新为拖动后的结果，直接提交即可
            onCommit?(items, String(localized: "Move Annotation"))

        case .resizing:
            onCommit?(items, String(localized: "Resize Annotation"))

        case .none:
            break
        }
        interaction = .none
        needsDisplay = true
    }

    // MARK: - 【新增】原文文本选择

    /// 视图坐标 → PDF 页面坐标（原点左下，与 page.bounds(for:.cropBox) 同一坐标系）
    private func pagePoint(fromView p: CGPoint, in layout: PageLayout) -> CGPoint? {
        guard let page = pdfDocument?.page(at: layout.index) else { return nil }
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 1, crop.height > 1 else { return nil }
        let nx = (p.x - layout.rect.minX) / max(1, layout.rect.width)
        let ny = (p.y - layout.rect.minY) / max(1, layout.rect.height)
        return CGPoint(x: crop.minX + nx * crop.width, y: crop.maxY - ny * crop.height)
    }

    /// PDF 页面坐标 → 视图坐标
    private func viewRect(fromPageRect r: CGRect, in layout: PageLayout) -> CGRect? {
        guard let page = pdfDocument?.page(at: layout.index) else { return nil }
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 1, crop.height > 1 else { return nil }
        let nx = (r.minX - crop.minX) / crop.width
        let ny = (crop.maxY - r.maxY) / crop.height
        return CGRect(
            x: layout.rect.minX + nx * layout.rect.width,
            y: layout.rect.minY + ny * layout.rect.height,
            width: r.width / crop.width * layout.rect.width,
            height: r.height / crop.height * layout.rect.height
        )
    }

    /// 视图坐标处是否落在「可选中的原文」上（用于悬停光标切换）。
    @discardableResult
    func isPointOverSelectableText(_ viewPoint: CGPoint) -> Bool {
        guard textSelectionEnabled else { return false }
        let layouts = computeLayouts()
        guard let (layout, page) = layoutAndPage(for: viewPoint, layouts: layouts),
              let pagePoint = pagePoint(fromView: viewPoint, in: layout) else { return false }
        // selectionForWordAtPoint 是单次命中测试，成本远低于遍历所有文本行；
        // 但 PDFKit 的词命中带有邻域容差（空白处也会返回最近的词），
        // 因此必须再确认该点确实落在词的包围盒内，光标才不会在空白处变成 I 形。
        guard let word = page.selectionForWord(at: pagePoint) else { return false }
        return word.bounds(for: page).insetBy(dx: -2, dy: -3).contains(pagePoint)
    }

    /// 用视图坐标建立原文选择，返回选中的文本。
    ///
    /// 抽成独立入口：交互（mouseDown/Dragged）与单元测试共用同一段逻辑。
    @discardableResult
    func selectText(fromViewPoint anchor: CGPoint, toViewPoint current: CGPoint) -> String? {
        let layouts = computeLayouts()
        guard let (layout, _) = layoutAndPage(for: anchor, layouts: layouts) else { return nil }
        applyTextSelection(from: anchor, to: current, layout: layout)
        needsDisplay = true
        return textSelection?.string
    }

    /// 用「起点→终点」建立选择（PDFKit 会按阅读顺序自动处理方向与跨行）
    private func applyTextSelection(from anchor: CGPoint, to current: CGPoint, layout: PageLayout) {
        guard let page = pdfDocument?.page(at: layout.index),
              let a = pagePoint(fromView: anchor, in: layout),
              let b = pagePoint(fromView: current, in: layout) else { return }
        textSelection = page.selection(from: a, to: b)
    }

    private func drawTextSelection(_ selection: PDFSelection, layouts: [PageLayout]) {
        let fill = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45)
        fill.setFill()
        for line in selection.selectionsByLine() {
            for page in line.pages {
                guard let index = pdfDocument?.index(for: page),
                      let layout = layout(forPage: index, in: layouts),
                      let rect = viewRect(fromPageRect: line.bounds(for: page), in: layout) else { continue }
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    /// 边缘拖动时自动滚动，便于跨页选择
    private func autoScrollIfNeeded(towards point: CGPoint) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let edge: CGFloat = 24
        var origin = clip.bounds.origin
        if point.y < clip.bounds.minY + edge { origin.y -= 12 }
        if point.y > clip.bounds.maxY - edge { origin.y += 12 }
        if point.x < clip.bounds.minX + edge { origin.x -= 12 }
        if point.x > clip.bounds.maxX - edge { origin.x += 12 }
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// ⌘C：复制选中的原文（响应链上的标准 copy: 动作）
    @objc func copy(_ sender: Any?) {
        guard textSelectionEnabled, let text = textSelection?.string, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onTextSelectionChanged?(text)
    }

    /// ⌘A：全选当前页文本（NSResponder 已声明 selectAll:，故需 override）
    @objc override func selectAll(_ sender: Any?) {
        guard textSelectionEnabled,
              let layout = computeLayouts().first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(mouseLocationInView()) })
                ?? computeLayouts().first,
              let page = pdfDocument?.page(at: layout.index) else { return }
        textSelection = page.selection(for: page.bounds(for: .cropBox))
        onTextSelectionChanged?(textSelection?.string)
        needsDisplay = true
    }

    private func mouseLocationInView() -> CGPoint {
        guard let window else { return .zero }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// 清空原文选择
    func clearTextSelection() {
        guard textSelection != nil else { return }
        textSelection = nil
        needsDisplay = true
        onTextSelectionChanged?(nil)
    }

    @objc func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return textSelectionEnabled && !((textSelection?.string ?? "").isEmpty)
        }
        if item.action == #selector(selectAll(_:)) {
            return textSelectionEnabled
        }
        return true
    }

    /// 拖动过程中的实时预览：只改本地数组，不登记撤销
    private func applyLive(_ item: PDFAnnotationItem, id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            var next = items
            next[index] = item
            items = next
        }
    }

    // MARK: - 文本编辑

    private func beginTextEditing(_ item: PDFAnnotationItem, in layout: PageLayout, isNew: Bool = false) {
        commitTextEditingIfNeeded()
        let rect = viewRect(for: item, layouts: computeLayouts())
            ?? CGRect(x: pageMargin, y: pageMargin, width: 160, height: 40)

        let field = NSTextField(frame: rect)
        field.stringValue = item.text
        field.font = NSFont.systemFont(ofSize: max(8, item.fontSize * zoom))
        field.textColor = item.color
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldSubmitted(_:))
        addSubview(field)
        editingField = field
        editingItemID = item.id
        editingIsNew = isNew

        if isNew {
            // 先把空文本加入（若用户取消则回滚）
            var next = items
            next.append(item)
            items = next
        }
        window?.makeFirstResponder(field)
    }

    @objc private func textFieldSubmitted(_ sender: NSTextField) {
        commitTextEditingIfNeeded()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditingIfNeeded()
    }

    private func commitTextEditingIfNeeded() {
        guard let field = editingField, let id = editingItemID else { return }
        let newText = field.stringValue
        let wasNew = editingIsNew
        field.removeFromSuperview()
        editingField = nil
        editingItemID = nil
        editingIsNew = false

        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        item.text = newText

        var next = items
        if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next.remove(at: index)
            onCommit?(next, wasNew ? String(localized: "Add Text") : String(localized: "Delete Text"))
            onSelect?(nil)
        } else {
            next[index] = item
            onCommit?(next, wasNew ? String(localized: "Add Text") : String(localized: "Edit Text"))
            onSelect?(item.id)
        }
        needsDisplay = true
    }

    // MARK: - 键盘

    /// 双指捏合缩放：以指针位置为锚点，保证指针下的内容不动
    override func magnify(with event: NSEvent) {
        guard event.magnification != 0, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        guard clip.bounds.width > 1, clip.bounds.height > 1 else { return }

        let newZoom = min(max(zoom * (1 + event.magnification), 0.25), 5.0)
        guard abs(newZoom - zoom) > 0.0001 else { return }

        // 缩放前：指针在文档视图与裁剪视图中的位置
        let anchorInDoc = convert(event.locationInWindow, from: nil)
        let anchorInClip = clip.convert(event.locationInWindow, from: nil)
        let scaleRatio = newZoom / zoom

        zoom = newZoom   // 触发 frame 重算与缩略图缓存清空
        updateFrameSize()

        // 缩放后：同一文档坐标点的新位置 - 指针在裁剪视图中的位置 = 新原点
        let newAnchorInDoc = CGPoint(x: anchorInDoc.x * scaleRatio, y: anchorInDoc.y * scaleRatio)
        let proposed = CGPoint(x: newAnchorInDoc.x - anchorInClip.x, y: newAnchorInDoc.y - anchorInClip.y)
        let constrained = clip.constrainBoundsRect(CGRect(origin: proposed, size: clip.bounds.size)).origin
        clip.scroll(to: constrained)
        scroll.reflectScrolledClipView(clip)

        onZoomChanged?(newZoom)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onSelect?(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
            if let id = selectedItemID {
                onCommit?(items.filter { $0.id != id }, String(localized: "Delete Annotation"))
                onSelect?(nil)
                return
            }
        }
        super.keyDown(with: event)
    }
}

#endif // os(macOS)
