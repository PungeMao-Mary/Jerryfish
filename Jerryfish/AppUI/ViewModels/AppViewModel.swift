import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// ============================================================
// 业务编排中枢（State / Action）
//
// 只依赖 CoreBackend 的服务，不直接接触任何底层框架细节；
// 所有耗时环节（截屏 / OCR / 翻译）都在后台执行，主线程只做状态更新。
// ============================================================

/// 流水线各阶段耗时（毫秒），用于在 UI 上展示「极低延迟」的真实数据。
struct PipelineTimings: Equatable, Sendable {
    var capture: Double = 0
    var ocr: Double = 0
    var sanitize: Double = 0
    var translate: Double = 0
    var total: Double = 0

    var summary: String {
        String(format: "截屏 %.0fms · OCR %.0fms · 清洗 %.1fms · 翻译 %.0fms · 合计 %.0fms",
               capture, ocr, sanitize, translate, total)
    }
}

/// 需要用户介入的错误。
enum AppFailure: Identifiable, Equatable {
    case screenRecordingPermission
    case languagePackMissing
    case engineNotReady(String?)
    case capture(String)
    case ocr(String)
    case translation(String)
    case pdf(String)

    var id: String { title + message }

    var title: String {
        switch self {
        case .screenRecordingPermission: return String(localized: "缺少屏幕录制权限")
        case .languagePackMissing: return String(localized: "缺少离线翻译语言包")
        case .engineNotReady: return String(localized: "翻译引擎尚未就绪")
        case .capture: return String(localized: "截屏失败")
        case .ocr: return String(localized: "文字识别失败")
        case .translation: return String(localized: "翻译失败")
        case .pdf: return String(localized: "PDF 处理失败")
        }
    }

    var message: String {
        switch self {
        case .screenRecordingPermission:
            return String(localized: "请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选本应用，然后重新启动本应用（macOS 要求重启后授权才生效）。")
        case .languagePackMissing:
            return String(localized: "系统尚未安装「\(UserSettingsManager.shared.sourceLanguage.description)」离线翻译包。可在本应用中一键下载，或前往系统设置手动安装。")
        case .engineNotReady(let detail):
            if UserSettingsManager.shared.showsPerformanceMetrics,
               let detail, !detail.isEmpty {
                return String(localized: "系统翻译会话仍在建立中，请稍候再试一次。\n\n诊断：") + detail
            }
            return String(localized: "系统翻译会话仍在建立中，请稍候再试一次。")
        case .capture(let reason): return reason
        case .ocr(let reason): return reason
        case .translation(let reason): return reason
        case .pdf(let reason): return reason
        }
    }

    /// 可一键执行的补救动作。
    var recovery: Recovery? {
        switch self {
        case .screenRecordingPermission: return .openScreenRecordingSettings
        case .languagePackMissing: return .downloadLanguagePack
        case .engineNotReady: return .restartEngine
        default: return nil
        }
    }

    enum Recovery: Equatable {
        case openScreenRecordingSettings
        case downloadLanguagePack
        case restartEngine

        var title: String {
            switch self {
            case .openScreenRecordingSettings: return String(localized: "打开系统设置")
            case .downloadLanguagePack: return String(localized: "下载离线语言包")
            case .restartEngine: return String(localized: "重新激活引擎")
            }
        }
    }
}

@Observable
@MainActor
final class AppViewModel {

    /// 停止输入后自动翻译的防抖时长。
    static let autoTranslateDelay: Duration = .milliseconds(1500)

    // MARK: - 状态

    var inputText: String = ""
    var translatedText: String = ""
    /// 逻辑忙碌标记：立即置位，用于禁用按钮 / 阻止并发请求。
    var isBusy = false
    /// 界面上的加载框是否可见。
    ///
    /// 本地离线翻译通常只要 30~100ms，如果立刻显示加载框就会「闪一下」非常刺眼，
    /// 因此只有超过 `busyIndicatorThreshold` 仍未完成时才显示。
    var showsBusyIndicator = false
    var activityLabel: String = ""

    /// 加载框出现的延迟阈值。
    static let busyIndicatorThreshold: Duration = .milliseconds(450)
    private var busyIndicatorTask: Task<Void, Never>?
    var lastError: AppFailure?
    var timings: PipelineTimings?
    var lastOCRResult: OCRResult?

    /// 设置 Sheet 是否展示（由菜单 ⌘, 或底部「设置」按钮驱动）
    var isSettingsPresented = false

    /// 自动翻译的防抖任务
    private var autoTranslateTask: Task<Void, Never>?
    /// 最近一次「已尝试翻译」的原文，避免同一段文本被反复翻译
    private var lastAttemptedSource: String?

    /// 当前 PDF 窗口应展示的文档（由「打开」按钮写入，PDF 窗口读取）
    var activePDFURL: URL?

    /// OCR 引擎预热状态。
    ///
    /// macOS 26/27 的 Vision 首次识别约需 20+ 秒（模型资产加载），预热后约 0.12 秒，
    /// 因此在启动时后台预热，并在 UI 上如实展示状态。
    enum WarmUpState: Equatable {
        case idle
        case warming
        case ready
        case failed

        var localizedDescription: String? {
            switch self {
            case .idle: return nil
            case .warming: return "OCR 引擎预热中（仅首次，约 20 秒）"
            case .ready: return nil
            case .failed: return "OCR 引擎预热失败"
            }
        }
    }

    private(set) var ocrWarmUpState: WarmUpState = .idle
    private var ocrWarmUpTask: Task<Bool, Never>?
    private var ocrKeepWarmTask: Task<Void, Never>?
    private var didBootstrap = false

    let translationService: TranslationService
    private let injectedOCRService: VisionOCRService?
    private let hotkeys: GlobalHotkeyManager

    private var captureController: CaptureOverlayController?
    private var persistentSelectionController: CaptureOverlayController?
    private var persistentTranslationController: PersistentTranslationController?
    private(set) var isPersistentTranslationActive = false
    private(set) var persistentTranslationStatus: String?
    /// 当前截屏会话（遮罩存活期间一直存在）
    private(set) var captureSession: CaptureSessionModel?

    var isCapturing: Bool { captureController != nil }

    init(
        translationService: TranslationService? = nil,
        ocrService: VisionOCRService? = nil,
        hotkeys: GlobalHotkeyManager? = nil
    ) {
        // 默认参数表达式在 nonisolated 环境求值，因此这里用可选出厂值，
        // 在 MainActor 隔离的 init 体内完成构造与解析。
        self.translationService = translationService ?? TranslationService()
        self.injectedOCRService = ocrService
        self.hotkeys = hotkeys ?? .shared
    }

    private var ocrService: VisionOCRService {
        injectedOCRService ?? VisionOCRService(configuration: .init(
            languages: [UserSettingsManager.shared.sourceLanguage.visionIdentifier],
            recognitionLevel: .accurate,
            automaticallyDetectsLanguage: false
        ))
    }

    // MARK: - 引擎

    var engineReadiness: TranslationService.Readiness { translationService.readiness }

    /// 应用回到前台时重新确认离线包状态。
    ///
    /// 用户很可能是「切到系统设置装好语言包 → 切回来」，必须能立刻用上，
    /// 而不是因为一次历史探测结果被永久判定为「未安装」。
    func refreshEngineAvailability() async {
        await translationService.refreshAvailability(force: true)
        await translationService.prewarmIfReady()
    }

    func sourceLanguageDidChange() async {
        lastAttemptedSource = nil
        await translationService.refreshForSelectedLanguage()
        persistentTranslationController?.updateLanguage(UserSettingsManager.shared.sourceLanguage)
        ocrWarmUpTask?.cancel()
        ocrWarmUpState = .warming
        let service = ocrService
        ocrWarmUpTask = Task { [weak self] in
            let ready = await service.warmUp()
            guard !Task.isCancelled else { return false }
            self?.ocrWarmUpState = ready ? .ready : .failed
            return ready
        }
    }

    // MARK: - 忙碌状态（带延迟的加载框）

    /// 开始一次可能耗时的操作。
    ///
    /// - Parameter showsIndicator: 是否允许显示加载框（长任务传 true，瞬时任务传 false）。
    private func beginBusy(_ label: String, showsIndicator: Bool = true) {
        isBusy = true
        activityLabel = label
        busyIndicatorTask?.cancel()
        guard showsIndicator else { return }
        busyIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.busyIndicatorThreshold)
            guard let self, !Task.isCancelled, self.isBusy else { return }
            withAnimation(.easeOut(duration: 0.12)) { self.showsBusyIndicator = true }
        }
    }

    private func endBusy() {
        busyIndicatorTask?.cancel()
        busyIndicatorTask = nil
        if showsBusyIndicator {
            withAnimation(.easeIn(duration: 0.12)) { showsBusyIndicator = false }
        }
        isBusy = false
        activityLabel = ""
    }

    func bootstrapEngine() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        await translationService.startTranslationTaskIfNeeded()
        await translationService.refreshAvailability(force: true)

        // OCR 模型预热放到后台任务里，不阻塞翻译引擎的建立
        if ocrWarmUpTask == nil {
            ocrWarmUpState = .warming
            let service = ocrService
            ocrWarmUpTask = Task { [weak self] in
                let ok = await service.warmUp()
                guard !Task.isCancelled else { return false }
                self?.ocrWarmUpState = ok ? .ready : .failed
                return ok
            }
        }

        // 语言包已安装时预热翻译引擎
        await translationService.prewarmIfReady()

        startOCRKeepWarmLoop()
    }

    /// 定期轻度热身 OCR 引擎。
    ///
    /// 实测：模型闲置一段时间后会被系统换出，下次首次识别需重新从磁盘载入（约 23 秒）。
    /// 每 5 分钟跑一次极小图的识别（约 100ms）即可让模型常驻，代价可忽略，
    /// 换来「任何时候按 ⌘⇧A 都是毫秒级」。
    private func startOCRKeepWarmLoop() {
        guard ocrKeepWarmTask == nil else { return }
        ocrKeepWarmTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                guard let service = self?.ocrService else { return }
                _ = await service.warmUp()
                // 保活失败（例如被系统限制）就不再空转
                if self?.ocrWarmUpState == .failed { return }
            }
        }
    }

    /// 等待 OCR 引擎预热完成（截屏流水线在识别前调用，避免用户误以为卡死）。
    func awaitOCRReady() async {
        guard let task = ocrWarmUpTask else { return }
        if ocrWarmUpState == .warming {
            activityLabel = String(localized: "正在预热 OCR 引擎（仅首次需要，约 20 秒）…")
            _ = await task.value
        }
    }

    func performRecovery(_ recovery: AppFailure.Recovery) {
        switch recovery {
        case .openScreenRecordingSettings:
            ScreenCapturePermission.openSystemSettings()
        case .downloadLanguagePack:
            Task { await downloadLanguagePack() }
        case .restartEngine:
            translationService.restartTranslationTask()
            lastError = nil
        }
    }

    func downloadLanguagePack() async {
        beginBusy(String(localized: "正在请求系统下载离线语言包…"))
        defer { endBusy() }

        let installed = await translationService.prepareOfflineLanguagePack()
        if installed {
            lastError = nil
        } else {
            lastError = .languagePackMissing
            ScreenCapturePermission.openTranslationSettings()
        }
    }

    // MARK: - 文本翻译

    /// 输入内容变化 → 3 秒防抖后自动翻译（可在设置中关闭）。
    func inputTextDidChange() {
        autoTranslateTask?.cancel()
        guard UserSettingsManager.shared.translationAutoTranslateEnabled else { return }
        let snapshot = inputText
        autoTranslateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoTranslateDelay)
            guard let self, !Task.isCancelled else { return }
            await self.autoTranslateIfNeeded(snapshot: snapshot)
        }
    }

    private func autoTranslateIfNeeded(snapshot: String) async {
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimumLength = UserSettingsManager.shared.sourceLanguage == .japanese ? 2 : 6
        guard trimmed.count >= minimumLength else { return }     // 太短不翻，避免噪声
        guard trimmed != lastAttemptedSource else { return }       // 未变化不重复翻
        guard !isBusy else { return }
        // 注意：这里必须直接调用翻译，不能走 translateCurrentInput()——
        // 后者会 cancel 掉 autoTranslateTask，而当前正运行在那个 task 里，
        // 等于「自己取消自己」，结果必然报「翻译已取消」。
        await performTranslation()
    }

    /// 用户主动触发（按钮 / ⌘↩）：先取消尚未执行的自动翻译，再翻译。
    func translateCurrentInput() async {
        autoTranslateTask?.cancel()
        await performTranslation()
    }

    private func performTranslation() async {
        let source = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            lastError = .translation(settingsInputPrompt)
            return
        }
        lastAttemptedSource = source
        // 本地翻译很快：加载框交给延迟机制决定是否出现
        beginBusy(String(localized: "正在本地离线翻译…"))
        defer { endBusy() }

        let started = ContinuousClock.now
        let sanitizeStart = ContinuousClock.now
        let cleaned = UserSettingsManager.shared.sourceLanguage == .japanese
            ? source.trimmingCharacters(in: .whitespacesAndNewlines)
            : TextSanitizer.cleanAcademicText(source)
        let sanitizeMs = TranslationService.milliseconds(since: sanitizeStart)

        do {
            let translated = try await translationService.translate(text: cleaned)
            let total = TranslationService.milliseconds(since: started)
            translatedText = translated
            timings = PipelineTimings(
                capture: 0,
                ocr: 0,
                sanitize: sanitizeMs,
                translate: max(0, total - sanitizeMs),
                total: total
            )
            // 原文永远保留在输入框里，绝不被译文覆盖
            lastError = nil
        } catch {
            // 被更新的请求取代而取消：静默处理，不弹告警
            if let serviceError = error as? TranslationServiceError, serviceError.isCancellation { return }
            if error is CancellationError { return }
            lastError = failure(from: error)
        }
    }

    /// 交换输入输出（对照模式下便于连续阅读）。
    func swapInputAndOutput() {
        let source = inputText
        inputText = translatedText
        translatedText = source
    }

    private var settingsInputPrompt: String {
        UserSettingsManager.shared.sourceLanguage == .english
            ? String(localized: "请先输入或粘贴英文内容。")
            : String(localized: "请先输入或粘贴日文内容。")
    }

    func clearAll() {
        inputText = ""
        translatedText = ""
        timings = nil
        lastOCRResult = nil
        lastError = nil
    }

    // MARK: - 截屏翻译

    // MARK: - 截屏翻译（有道式：选区后就地覆盖译文，点「完成」才退出）

    /// 进入截屏态（⌘⇧A 或主界面「截屏」按钮）。
    ///
    /// 注意：此处 **不能** 激活本应用 / 前置主窗口，否则用户正在阅读的文献
    /// 会被本应用窗口挡住；只有点「完成」后才唤回前台。
    func beginCaptureFlow() {
        guard captureController == nil, persistentSelectionController == nil else { return }
        lastError = nil

        let controller = CaptureOverlayController()
        let session = controller.session

        // 拖拽提示只在首次使用时出现
        if !UserSettingsManager.shared.hasShownCaptureHint {
            session.hintVisible = true
            UserSettingsManager.shared.hasShownCaptureHint = true
        }

        controller.onTranslateRequest = { [weak self] globalRect, panelRect, excluded in
            Task { @MainActor in
                await self?.runCapturePipeline(globalRect: globalRect,
                                               panelRect: panelRect,
                                               excluding: excluded)
            }
        }
        controller.onCopy = { [weak self] in
            self?.copyCaptureTranslation()
        }
        controller.onFinish = { [weak self] in
            self?.finishCaptureSession()
        }
        controller.onCancel = { [weak self] in
            self?.endCaptureSession()
        }
        controller.onDownloadLanguagePack = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.downloadLanguagePack()
                // 下载完成后自动重译当前选区
                self.captureController?.retranslate()
            }
        }

        captureController = controller
        captureSession = session
        controller.present()
    }

    /// 启动/停止常驻翻译。首次或 ⌘ 点击进入一次性框选；普通点击复用保存区域。
    func handlePersistentTranslationClick(commandHeld: Bool) {
        if commandHeld {
            stopPersistentTranslation()
            beginPersistentRegionSelection()
            return
        }
        if isPersistentTranslationActive {
            stopPersistentTranslation()
            return
        }
        if let region = UserSettingsManager.shared.persistentTranslationRegion,
           Self.isUsablePersistentRegion(region) {
            startPersistentTranslation(in: region)
        } else {
            beginPersistentRegionSelection()
        }
    }

    private static func isUsablePersistentRegion(_ region: CGRect) -> Bool {
        ScreenGeometry.activeDisplayBounds().contains { display in
            let visible = region.standardized.intersection(display.bounds)
            return visible.width >= ScreenCaptureService.minimumSelectionSide
                && visible.height >= ScreenCaptureService.minimumSelectionSide
        }
    }

    private func beginPersistentRegionSelection() {
        guard persistentSelectionController == nil, captureController == nil else { return }
        let controller = CaptureOverlayController()
        controller.selectionOnly = true
        controller.session.hintVisible = true
        controller.onRegionSelected = { [weak self, weak controller] region in
            guard let self else { return }
            if self.persistentSelectionController === controller {
                self.persistentSelectionController = nil
            }
            UserSettingsManager.shared.persistentTranslationRegion = region
            self.startPersistentTranslation(in: region)
        }
        controller.onCancel = { [weak self, weak controller] in
            guard let self else { return }
            if self.persistentSelectionController === controller {
                self.persistentSelectionController = nil
            }
        }
        persistentSelectionController = controller
        controller.present()
    }

    private func startPersistentTranslation(in region: CGRect) {
        persistentTranslationController?.stop()
        let controller = PersistentTranslationController(
            region: region,
            sourceLanguage: UserSettingsManager.shared.sourceLanguage,
            translationService: translationService,
            onStatus: { [weak self] status in
                self?.persistentTranslationStatus = status
            }
        ) { [weak self] failure in
            self?.lastError = failure
        }
        persistentTranslationController = controller
        isPersistentTranslationActive = true
        persistentTranslationStatus = "正在启动屏幕捕获…"
        lastError = nil
        Task { @MainActor [weak self, weak controller] in
            do {
                try await controller?.start()
            } catch {
                guard let self, let controller, self.persistentTranslationController === controller else { return }
                controller.stop()
                self.persistentTranslationController = nil
                self.isPersistentTranslationActive = false
                if let captureError = error as? ScreenCaptureError, case .permissionDenied = captureError {
                    ScreenCaptureService.requestPermission()
                    self.lastError = .screenRecordingPermission
                } else {
                    self.lastError = .capture(error.localizedDescription)
                }
                self.persistentTranslationStatus = "常驻翻译启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func stopPersistentTranslation() {
        persistentTranslationController?.stop()
        persistentTranslationController = nil
        isPersistentTranslationActive = false
        persistentTranslationStatus = nil
    }

    private func endCaptureSession() {
        captureController = nil
        captureSession = nil
    }

    /// 点「✓ 完成」：退出截屏态，并把原文 / 译文回填主窗口。
    private func finishCaptureSession() {
        defer { endCaptureSession() }
        guard let session = captureSession else { return }

        if session.hasResult {
            inputText = session.sourceText
            translatedText = session.translatedText
            // 已经有译文了：标记为「已尝试」，避免 3 秒后又被自动翻译一次
            lastAttemptedSource = session.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let reason = session.errorMessage {
            // 框选后没能生成译文时，把原因带回主界面，而不是静默退出
            lastError = .translation(reason)
        } else if session.translatedText.isEmpty {
            return
        }
        // 无论回填成功还是失败告警，都必须把主窗口带到前台，
        // 否则告警会落在用户当前应用后面，用户根本看不到（实测踩到）

        if UserSettingsManager.shared.autoActivateOnCapture {
            if NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) == nil {
                HotkeyRouter.shared.requestMainWindow()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func copyCaptureTranslation() {
        guard let session = captureSession, !session.translatedText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.translatedText, forType: .string)
        session.copyFeedback = true
        Task { @MainActor [weak session] in
            try? await Task.sleep(for: .milliseconds(1400))
            session?.copyFeedback = false
        }
    }

    /// 选区确定后：截屏 → OCR → 分段翻译 → 就地译文块（全程不退出截屏态）。
    private func runCapturePipeline(globalRect: CGRect,
                                    panelRect: CGRect,
                                    excluding excludedWindows: Set<Int>) async {
        guard let session = captureSession else { return }
        var timings = PipelineTimings()
        let overallStart = ContinuousClock.now

        session.blocks = []
        session.needsLanguagePack = false
        session.showsOriginal = false
        session.sourceText = ""
        session.translatedText = ""
        session.phase = .working(String(localized: "正在截取所选区域…"))

        // 1. 截屏
        let captureStart = ContinuousClock.now
        let image: CGImage
        do {
            image = try await ScreenCaptureService.captureRegion(globalRect,
                                                                excludingWindowNumbers: excludedWindows)
        } catch {
            if let captureError = error as? ScreenCaptureError, case .permissionDenied = captureError {
                // 权限不可用 → 整套流程无法工作，退出截屏并弹告警引导授权
                ScreenCaptureService.requestPermission()
                endCaptureSession()
                lastError = .screenRecordingPermission
            } else {
                session.phase = .failed(error.localizedDescription)
            }
            return
        }
        timings.capture = TranslationService.milliseconds(since: captureStart)

        // 2. OCR（首次需要等待模型预热）
        session.phase = .working(String(localized: "正在准备识别引擎…"))
        await awaitOCRReady()
        session.phase = .working(String(localized: "正在识别文字…"))

        let ocrStart = ContinuousClock.now
        let result: OCRResult
        do {
            result = try await ocrService.recognize(cgImage: image)
        } catch {
            session.phase = .failed(error.localizedDescription)
            return
        }
        timings.ocr = TranslationService.milliseconds(since: ocrStart)
        lastOCRResult = result

        let sourceParagraphs = result.blocks.map(\.text)
        guard !sourceParagraphs.isEmpty else {
            session.phase = .failed(String(localized: "未识别到所选语言文本，请重新框选。"))
            return
        }

        // 3. 分段批量翻译（一段一框，因此译文与段落严格一一对应）
        session.phase = .working(String(localized: "正在本地翻译…"))
        let translateStart = ContinuousClock.now
        do {
            let translations = try await translationService.batchTranslate(texts: sourceParagraphs)
            timings.translate = TranslationService.milliseconds(since: translateStart)
            timings.total = TranslationService.milliseconds(since: overallStart)
            timings.sanitize = 0
            self.timings = timings

            session.sourceText = sourceParagraphs.joined(separator: "\n\n")
            session.translatedText = translations
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            session.blocks = CaptureBlockLayout.makeBlocks(
                ocr: result,
                translations: translations,
                selection: panelRect
            )
            session.phase = session.blocks.isEmpty
                ? .failed(String(localized: "翻译结果为空，请重新框选。"))
                : .ready
            lastError = nil
        } catch {
            if let failure = failure(from: error) as AppFailure? {
                if case .languagePackMissing = failure {
                    session.needsLanguagePack = true
                    session.phase = .failed(String(localized: "尚未安装「\(UserSettingsManager.shared.sourceLanguage.description)」离线包，点右侧按钮下载后会自动重译。"))
                } else if case .engineNotReady = failure {
                    session.phase = .failed(
                        UserSettingsManager.shared.showsPerformanceMetrics
                            ? String(localized: "翻译引擎正在准备，请点「重译」再试一次。\n") + translationService.diagnostics
                            : String(localized: "翻译引擎正在准备，请点「重译」再试一次。")
                    )
                } else {
                    session.phase = .failed(failure.message)
                }
            } else {
                session.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - PDF

    func choosePDFAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "打开")
        panel.message = UserSettingsManager.shared.sourceLanguage == .english
            ? String(localized: "选择需要翻译批注的英文 PDF")
            : String(localized: "选择需要翻译批注的日文 PDF")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        activePDFURL = url
    }

    // MARK: - 错误映射

    func failure(from error: Error) -> AppFailure {
        if let serviceError = error as? TranslationServiceError {
            switch serviceError {
            case .languagePackMissing: return .languagePackMissing
            case .engineNotReady: return .engineNotReady(translationService.diagnostics)
            default: return .translation(serviceError.localizedDescription)
            }
        }
        if let ocrError = error as? OCRError {
            return .ocr(ocrError.localizedDescription)
        }
        if let pdfError = error as? PDFTranslationError {
            return .pdf(pdfError.localizedDescription)
        }
        return .translation(error.localizedDescription)
    }
}

// MARK: - 系统设置深链

enum ScreenCapturePermission {

    /// 「隐私与安全性 → 屏幕录制」
    static func openSystemSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// 「通用 → 语言与地区 → 翻译语言」
    static func openTranslationSettings() {
        if !open("x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            _ = open("x-apple.systempreferences:com.apple.preference.general")
        }
    }

    @discardableResult
    private static func open(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
