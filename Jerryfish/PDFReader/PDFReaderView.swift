#if os(macOS)
import SwiftUI
import PDFKit

// ============================================================
// 应用内 PDF 阅读器：只读 PDF + 内存批注（可撤销）。
// 顶部 Liquid Glass 胶囊工具栏 + 自绘 PDF 画布 + 右下角缩放控制。
// ============================================================

struct PDFReaderView: View {
    @Binding var document: LocusDocument
    @Bindable var workspace: WorkspaceState
    var pane: EditorPane? = nil

    @StateObject private var store: PDFAnnotationStore
    @State private var pdfDocument: PDFDocument?
    @State private var loadFailed = false
    @State private var zoom: CGFloat = 1.0
    @State private var zoomText: String = "100%"

    /// 【新增·可选】注入到顶部工具条里的附加按钮组（译文操作）
    var toolbarAccessory: AnyView?

    init(document: Binding<LocusDocument>, workspace: WorkspaceState, pane: EditorPane? = nil,
         store: PDFAnnotationStore? = nil, toolbarAccessory: AnyView? = nil) {
        self._document = document
        self.workspace = workspace
        self.pane = pane
        self.toolbarAccessory = toolbarAccessory
        // [桥接] 允许外部（PDFTranslationHostView）注入既定 store，
        // 以便把译文批注写入同一个批注图层；不传时行为与原先完全一致。
        _store = StateObject(wrappedValue: store ?? PDFAnnotationStore(workspace: workspace, documentID: document.wrappedValue.id))
    }

    private var fileURL: URL? {
        workspace.standaloneDocumentFileURLs[document.id]
    }

    var body: some View {
        // 工具条**悬浮**在文档之上，不再单独占一行：文档从窗口顶端开始铺满
        ZStack(alignment: .top) {
            ZStack(alignment: .bottomTrailing) {
                if let pdfDocument {
                    PDFCanvasRepresentable(
                        pdfDocument: pdfDocument,
                        items: store.items,
                        tool: store.tool,
                        colorHex: store.colorHex,
                        lineWidth: store.lineWidth,
                        fontSize: store.fontSize,
                        zoom: $zoom,
                        selectedItemID: store.selectedItemID,
                        performanceSaver: UserSettingsManager.shared.pdfPerformanceSaverMode,
                        onCommit: { newItems, name in store.apply(newItems, actionName: name) },
                        onSelect: { store.selectedItemID = $0 }
                    )
                } else if loadFailed {
                    unavailable
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                zoomControl
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PDFReaderToolbar(store: store, trailingAccessory: toolbarAccessory)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.locus(.textBackground))
        .onAppear(perform: loadIfNeeded)
        .onDisappear {
            // 离开时释放安全作用域访问权限，防止沙盒映射泄漏
            if let url = fileURL {
                url.stopAccessingSecurityScopedResource()
            }
        }
        .onChange(of: document.id) { _, _ in loadIfNeeded() }
        // 缩放值变化（滑条 / 捏合 / 百分比输入）→ 同步右下角百分比显示
        .onChange(of: zoom) { _, newValue in
            let text = "\(Int(round(newValue * 100)))%"
            if zoomText != text { zoomText = text }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text(String(localized: "无法打开 PDF"))
                .font(.headline)
            Text(fileURL?.path ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadIfNeeded() {
        guard pdfDocument == nil else { return }
        guard let url = fileURL else {
            loadFailed = true
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        pdfDocument = PDFDocument(url: url)
        loadFailed = (pdfDocument == nil)
    }

    // MARK: 右下角缩放控制

    private var zoomControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Slider(value: Binding(
                get: { Double(zoom) },
                set: { zoom = CGFloat($0) }
            ), in: 0.25...5.0)
            .frame(width: 130)

            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("", text: $zoomText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .frame(width: 54)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .onSubmit { applyZoomText() }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(PDFGlassCapsule())
    }

    private func applyZoomText() {
        let cleaned = zoomText.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let percent = Double(cleaned) {
            let clamped = min(500, max(25, percent))
            zoom = CGFloat(clamped / 100.0)
            zoomText = "\(Int(round(clamped)))%"
        } else {
            zoomText = "\(Int(round(zoom * 100)))%"
        }
    }
}

// MARK: - NSViewRepresentable

struct PDFCanvasRepresentable: NSViewRepresentable {
    let pdfDocument: PDFDocument?
    let items: [PDFAnnotationItem]
    let tool: PDFReaderTool
    let colorHex: String
    let lineWidth: CGFloat
    let fontSize: CGFloat
    @Binding var zoom: CGFloat
    let selectedItemID: UUID?
    /// 【新增】性能节约模式（低分辨率渲染 + 缩放复用）
    let performanceSaver: Bool
    let onCommit: ([PDFAnnotationItem], String) -> Void
    let onSelect: (UUID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // 自己实现双指捏合锚点缩放，禁用 ScrollView 原生缩放
        scroll.allowsMagnification = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder

        let canvas = PDFCanvasView()
        canvas.autoresizingMask = []
        scroll.documentView = canvas
        return scroll
    }

    // MARK: - [增量修改] 补充 dismantleNSView：Tab 关闭时立刻切断文档引用释放大内存
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let canvas = nsView.documentView as? PDFCanvasView {
            canvas.pdfDocument = nil
            canvas.items = []
        }
        coordinator.lastDocument = nil
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? PDFCanvasView else { return }

        canvas.onCommit = onCommit
        canvas.onSelect = onSelect
        // 双指捏合（妙控板）直接改画布缩放，再回写 SwiftUI 让缩放条/百分比同步
        canvas.onZoomChanged = { newZoom in
            if abs(newZoom - zoom) > 0.0001 { zoom = newZoom }
        }

        // PDFDocument 是引用类型：仅在真正换文档时重设，避免反复清空缩略图缓存
        let docChanged = (canvas.pdfDocument !== pdfDocument)
        if docChanged {
            canvas.pdfDocument = pdfDocument
            context.coordinator.lastDocument = pdfDocument
            context.coordinator.didInitialScroll = false
        }
        canvas.tool = tool
        canvas.colorHex = colorHex
        canvas.lineWidth = lineWidth
        canvas.fontSize = fontSize
        canvas.performanceSaverMode = performanceSaver
        canvas.zoom = zoom
        canvas.items = items
        canvas.selectedItemID = selectedItemID
        canvas.updateFrameSize()
        
        // 只有文档改变或标注改变时才重绘，不再每帧无脑 needsDisplay！
        if docChanged {
            canvas.needsDisplay = true
        }

        // 首次载入：水平居中、顶部对齐（而不是贴左上角）
        if pdfDocument != nil, !context.coordinator.didInitialScroll {
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                guard !coordinator.didInitialScroll else { return }
                Self.scrollToInitialPosition(scroll, canvas, coordinator: coordinator)
            }
        }
    }

    /// 把 PDF 内容水平居中、滚到顶部
    private static func scrollToInitialPosition(_ scroll: NSScrollView, _ canvas: NSView, coordinator: Coordinator) {
        let clip = scroll.contentView
        guard clip.bounds.width > 1, clip.bounds.height > 1, canvas.frame.height > 1 else { return }
        let x = max(0, (canvas.frame.width - clip.bounds.width) / 2)
        let proposed = CGRect(x: x, y: 0, width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
        coordinator.didInitialScroll = true
    }

    final class Coordinator {
        var didInitialScroll = false
        var lastDocument: PDFDocument?
    }
}

// MARK: - 玻璃胶囊（与 Markdown 工具栏同款）

struct PDFGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: Capsule(style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

#endif // os(macOS)
