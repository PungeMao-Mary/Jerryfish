import Observation
import SwiftUI

// ============================================================
// PDF 翻译宿主视图（桥接层）
//
// 职责：
//   1. 用 `LocusDocument` + `WorkspaceState` 满足既有 `PDFReaderView` 的宿主契约；
//   2. 把「4 个 PDF*.swift 组件」原样挂载进来（不改其自绘 / 交互逻辑）；
//   3. 执行「提取 → 翻译 → 生成批注 → 写入 PDFAnnotationStore」的映射；
//   4. 译文以 `PDFAnnotationItem(kind: .text)` 形式原地叠加，
//      随后即可用现成的 PDFReaderToolbar 自由二次圈画 / 移动 / 删除。
// ============================================================

/// 全篇翻译进度（跨隔离域只读 @MainActor 引用，线程安全）。
@Observable
@MainActor
final class PDFTranslationProgress {
    var done = 0
    var total = 0
}

struct PDFTranslationHostView: View {

    let pdfURL: URL
    let translationService: TranslationService

    @State private var document: LocusDocument
    @State private var workspace: WorkspaceState
    @StateObject private var store: PDFAnnotationStore
    @State private var progress = PDFTranslationProgress()

    @State private var status: Status = .idle
    @State private var showTranslationLayer = true
    @State private var hiddenTranslations: [PDFAnnotationItem] = []
    /// 进行中的整篇翻译任务（关窗 / 换文档时取消）
    @State private var translationTask: Task<Void, Never>?
    /// 点击工具栏「打开 PDF」时回调（宿主负责弹出选择面板并切换文档）
    var onOpenAnotherPDF: (() -> Void)?
    /// 沙盒：持有一份安全作用域访问权限，供提取器与 PDFKit 共享
    @State private var holdsSecurityScope = false

    init(pdfURL: URL, translationService: TranslationService, onOpenAnotherPDF: (() -> Void)? = nil) {
        self.pdfURL = pdfURL
        self.translationService = translationService
        self.onOpenAnotherPDF = onOpenAnotherPDF

        let doc = LocusDocument(title: pdfURL.lastPathComponent, fileURL: pdfURL)
        // PDFAnnotationStore 依赖 WorkspaceState 提供文档级撤销管理器
        let workspace = WorkspaceState()
        workspace.standaloneDocumentFileURLs[doc.id] = pdfURL

        _document = State(initialValue: doc)
        _workspace = State(initialValue: workspace)
        _store = StateObject(wrappedValue: PDFAnnotationStore(workspace: workspace, documentID: doc.id))
    }

    var body: some View {
        // 工具条悬浮在文档之上；译文相关按钮与批注工具同处一个胶囊
        PDFReaderView(
            document: $document,
            workspace: workspace,
            pane: .pdf,
            store: store,
            toolbarAccessory: AnyView(toolbarAccessory)
        )
        // 状态提示单独悬浮在右上角，不占布局、不挤工具条
        .overlay(alignment: .topTrailing) { floatingStatus }
        .frame(minWidth: 900, minHeight: 660)
        .navigationTitle(document.title.isEmpty ? "Jerryfish" : "\(document.title) — Jerryfish")
        .onAppear {
            registerMenuCommands()
            if !holdsSecurityScope {
                holdsSecurityScope = pdfURL.startAccessingSecurityScopedResource()
            }
            workspace.standaloneDocumentFileURLs[document.id] = pdfURL
        }
        .onDisappear {
            // 关闭窗口即释放：批注只存在于内存，不写回 PDF
            if holdsSecurityScope {
                pdfURL.stopAccessingSecurityScopedResource()
                holdsSecurityScope = false
            }
            workspace.removeDocument(id: document.id)
            // 取消可能仍在进行的整篇翻译：关窗/换文档后不该继续在后台跑 OCR 与翻译
            translationTask?.cancel()
            translationTask = nil
            PDFCommandRouter.shared.reset()
        }
    }

    // MARK: - 注入到悬浮工具条的译文按钮组

    @ViewBuilder
    private var toolbarAccessory: some View {
        HStack(spacing: 2) {
            Button {
                onOpenAnotherPDF?()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "打开 PDF（替换当前文档）"))

            Button {
                startTranslation()
            } label: {
                // `translate` 是 SF Symbols 里语义最直白的翻译图标（文/A 双字），
                // 比原来的气泡更一眼看懂
                Image(systemName: "translate")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 22)
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
            .help(String(localized: "翻译全文（⌘⇧T）"))

            if hasAnyTranslation {
                Button {
                    setTranslationLayerVisible(!showTranslationLayer)
                } label: {
                    Image(systemName: showTranslationLayer ? "eye" : "eye.slash")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 22)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.borderless)
                .help(showTranslationLayer
                      ? String(localized: "隐藏译文图层（只显示原文）")
                      : String(localized: "重新显示译文图层"))
            }
        }
    }

    // MARK: - 悬浮状态 / 页码提示

    @ViewBuilder
    private var floatingStatus: some View {
        if let chip = statusChip {
            HStack(spacing: 6) {
                if isWorking { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Text(chip.text)
                    .font(.system(size: 11))
                    .foregroundStyle(chip.tint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .modifier(PDFGlassCapsule())
            .padding(.trailing, 14)
            .padding(.top, 52)
            .allowsHitTesting(false)
        }
    }

    private var statusChip: (text: String, tint: Color)? {
        switch status {
        case .idle: return nil
        case .extracting: return (String(localized: "正在提取文本并定位…"), .secondary)
        case .translating:
            return (progress.total > 0
                    ? String(localized: "本地翻译中 \(progress.done)/\(progress.total) 段…")
                    : String(localized: "本地翻译中…"), .secondary)
        case .finished(let created, let ocrPages):
            return (ocrPages > 0
                    ? String(localized: "已生成 \(created) 条译文批注（\(ocrPages) 页经 OCR）")
                    : String(localized: "已生成 \(created) 条译文批注"), .secondary)
        case .failed(let message):
            return (message, .orange)
        }
    }


    // MARK: - 流程

    private var isWorking: Bool {
        switch status {
        case .extracting, .translating: return true
        default: return false
        }
    }

    private func translate() async {
        status = .extracting
        progress.done = 0
        progress.total = 0

        do {
            let sourceLanguage = UserSettingsManager.shared.sourceLanguage
            let extractor = PDFTextExtractor(
                ocrService: VisionOCRService(configuration: .init(
                    languages: [sourceLanguage.visionIdentifier],
                    recognitionLevel: .accurate,
                    automaticallyDetectsLanguage: false
                )),
                options: PDFExtractionOptions(pages: .all),
                sourceLanguage: sourceLanguage
            )
            let result = try await extractor.extract(from: pdfURL)

            guard !result.paragraphs.isEmpty else {
                status = .failed(String(localized: "未提取到可翻译文本"))
                return
            }

            status = .translating
            progress.total = result.paragraphs.count

            let translations = try await translationService.batchTranslate(
                texts: result.paragraphs.map(\.text)
            ) { [progress] done, total in
                progress.done = done
                progress.total = total
            }

            let items = PDFTranslationAnnotationFactory.makeAnnotations(
                paragraphs: result.paragraphs,
                translations: translations,
                pageSizes: result.pageSizesInPoints,
                colorHex: PDFTranslationAnnotationFactory.defaultColorHex,
                layout: PDFTranslationOverlayLayout.Options(
                    fontScale: UserSettingsManager.shared.pdfOverlayFontScale
                )
            )

            guard !items.isEmpty else {
                status = .failed(String(localized: "翻译结果为空（请确认离线语言包已安装）"))
                return
            }

            // 写入批注商店（参与文档级撤销 / 重做）
            var next = store.items.filter { !isTranslationItem($0) }
            next.append(contentsOf: items)
            store.apply(next, actionName: String(localized: "生成译文批注"))
            hiddenTranslations = []

            withAnimation(.easeInOut(duration: 0.15)) {
                showTranslationLayer = true
            }
            status = .finished(created: items.count, ocrPages: result.ocrPageIndices.count)

        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - 清理

    private func clearTranslations() {
        let next = store.items.filter { !isTranslationItem($0) }
        store.apply(next, actionName: String(localized: "清除译文批注"))
        hiddenTranslations = []
        progress = PDFTranslationProgress()
        status = .idle
    }

    /// 译文批注使用固定蓝色，据此与用户手绘批注区分。
    private func isTranslationItem(_ item: PDFAnnotationItem) -> Bool {
        item.kind == .text
            && item.colorHex.uppercased() == PDFTranslationAnnotationFactory.defaultColorHex.uppercased()
    }

    /// 是否还有译文（可见的或暂时被隐藏的都算）。
    private var hasAnyTranslation: Bool {
        store.items.contains(where: isTranslationItem) || !hiddenTranslations.isEmpty
    }

    /// 图层显隐：直接改 store 的 items（不登记撤销，属于纯显示层行为）。
    ///
    /// 由按钮显式调用而不是靠 onChange 观察：避免「隐身后按钮因 store.items 变空而被禁用，
    /// 于是再也切不回来」这类死锁（实测踩到）。
    private func setTranslationLayerVisible(_ visible: Bool) {
        showTranslationLayer = visible
        if visible {
            guard !hiddenTranslations.isEmpty else { return }
            store.items.append(contentsOf: hiddenTranslations)
            hiddenTranslations.removeAll()
        } else {
            let translations = store.items.filter { isTranslationItem($0) }
            guard !translations.isEmpty else { return }
            hiddenTranslations = translations
            store.items.removeAll { isTranslationItem($0) }
        }
    }

    /// 让菜单栏的「翻译 PDF 全文 / 此页 / 清除译文」作用于当前 PDF 窗口
    private func registerMenuCommands() {
        let router = PDFCommandRouter.shared
        router.translateAll = { startTranslation() }
        router.clearTranslations = { clearTranslations() }
        router.openPDF = { onOpenAnotherPDF?() }
    }

    private func startTranslation() {
        translationTask?.cancel()
        translationTask = Task { await translate() }
    }

    enum Status: Equatable {
        case idle
        case extracting
        case translating
        case finished(created: Int, ocrPages: Int)
        case failed(String)
    }
}
