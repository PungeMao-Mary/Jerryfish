import Foundation
import Observation
import Translation

// ============================================================
// 翻译后端（macOS 15+ Translation.framework 桥接）
//
// 核心约束：`TranslationSession` 由 SwiftUI 的 `.translationTask` 提供，
// 且只在 action 闭包存活期间有效；同时它是 **非 Sendable** 的 class。
//
// 因此这里的架构是：
//   - SwiftUI 侧挂一个无头宿主视图（`TranslationSessionHost`），把 session 交给 `serve(session:)`；
//   - `serve` 是 nonisolated 的，session 全程只在这一个隔离域内使用，绝不跨域传递；
//   - 需要翻译时，UI 侧把「任务」丢进队列并 await 一个 continuation；
//   - session 生灭 / 换代由令牌管理：新 session 会「顶掉」旧 session，旧循环自行退出。
//
// 这样既满足 Swift 6 并发检查，又让翻译能力可以在任意时刻、任意窗口按需调用。
// ============================================================

// MARK: - 引擎协议

/// 翻译引擎抽象。UI 层只依赖此协议，便于替换实现（例如未来的本地 LLM 引擎）。
public protocol TranslationEngineProtocol: Sendable {
    func translate(text: String) async throws -> String
    func batchTranslate(texts: [String]) async throws -> [String]
}

// MARK: - 错误

nonisolated public enum TranslationServiceError: LocalizedError, Sendable {
    case engineNotReady
    case languagePackMissing
    case emptyInput
    case cancelled
    case unsupportedLanguagePair(String)
    case underlying(String)

    /// 便于区分「被取消」这类良性终态。
    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return String(localized: "翻译引擎尚未就绪，请稍候重试。")
        case .languagePackMissing:
            return String(localized: "系统中尚未安装当前原文语言对应的离线翻译包。请点击「下载离线语言包」，或在系统设置 → 通用 → 语言与地区 → 翻译语言 中安装。")
        case .emptyInput:
            return String(localized: "没有可翻译的内容。")
        case .cancelled:
            return String(localized: "翻译已取消。")
        case .unsupportedLanguagePair(let pair):
            return String(localized: "当前系统不支持该语言对：\(pair)")
        case .underlying(let message):
            return message
        }
    }
}

// MARK: - 任务

nonisolated public enum TranslationSourceLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case japanese = "ja"

    public var id: String { rawValue }
    public var title: String { self == .english ? String(localized: "英语") : String(localized: "日语") }
    public var visionIdentifier: String { self == .english ? "en-US" : "ja-JP" }
    public var description: String { self == .english ? "英语 → 简体中文" : "日语 → 简体中文" }
}

/// 投递给活跃 session 的任务单元（Sendable，才能跨隔离域进入 serve 循环）。
nonisolated enum TranslationJob: Sendable {
    struct Item: Sendable {
        var id: UUID
        var text: String
    }

    case single(id: UUID, text: String)
    case batch(batchID: UUID, items: [Item])
    case prepare(requestID: UUID, restartOnSuccess: Bool)
}

// MARK: - 服务

@Observable
public final class TranslationService: TranslationEngineProtocol {

    /// 引擎就绪状态（供 UI 展示与引导下载离线包）。
    public enum Readiness: Equatable, Sendable {
        case idle
        case checking
        case ready
        case needsDownload
        case unsupported(String)
        case failed(String)

        public var isReady: Bool { self == .ready }

        public var localizedDescription: String {
            switch self {
            case .idle: return String(localized: "未初始化")
            case .checking: return String(localized: "正在检查离线语言包…")
            case .ready: return String(localized: "离线翻译包已就绪")
            case .needsDownload: return String(localized: "离线翻译包未安装")
            case .unsupported(let pair): return String(localized: "系统不支持该语言对：\(pair)")
            case .failed(let message): return String(localized: "翻译引擎异常：\(message)")
            }
        }
    }

    /// 翻译语言方向（本工具语义上固化「英语 → 简体中文」）。
    ///
    /// ⚠️ 但**不能**把语言标识写死成裸 `"en"`：framework 会把它解析成 `en-Latn-US`，
    /// 而系统「翻译语言」里用户装的可能是 **English (UK)**（本机实测正是 en_GB + zh_CN）。
    /// 一旦变体不匹配，`LanguageAvailability` 永远返回 `.supported`（未安装），
    /// 表现为「明明装了离线包却一直提示未安装」。
    ///
    /// 因此改为：枚举框架支持的 en / zh-Hans 变体，探测出**真正已安装**的组合来使用。
    nonisolated public static let sourceLanguageIdentifier = "en"
    nonisolated public static let targetLanguageIdentifier = "zh-Hans"
    nonisolated public static let languagePairDescription = "英语 → 简体中文"

    /// 解析出的、真正可用的语言对。
    public struct ResolvedPair: Equatable, Sendable {
        public var source: Locale.Language
        public var target: Locale.Language
        public var isInstalled: Bool

        public var description: String {
            "\(source.maximalIdentifier) → \(target.maximalIdentifier)"
        }
    }

    /// 单次批量的最大条目数；Translation.framework 内部会自行流水线化。
    nonisolated public static let defaultBatchSize = 24

    // MARK: 可观察状态

    public private(set) var readiness: Readiness = .idle

    /// 交给 `.translationTask` 的配置；`restartTranslationTask()` 通过 `invalidate()` 换代。
    public private(set) var configuration: TranslationSession.Configuration?

    /// 已完成翻译的条目总数与最近一次耗时（毫秒），用于 UI 展示真实延迟。
    /// 已解析的语言对（真正被系统认可的组合）。
    public private(set) var resolvedPair: ResolvedPair?
    /// 语言对描述，便于诊断「为什么说没装离线包」。
    public private(set) var configurationPairDescription: String?
    /// 系统是否允许本应用发起语言资产下载（macOS 26+；false 时只能引导去系统设置）。
    public private(set) var canRequestDownloads = false
    /// 会话代数：每次新 session 接管 +1，便于诊断「会话反复重建」类问题。
    public private(set) var sessionGeneration: Int = 0

    public private(set) var completedTranslationCount: Int = 0
    public private(set) var lastLatencyMilliseconds: Double = 0

    private var resolvedSourceIdentifier: String?
    private var currentSourceLanguage: TranslationSourceLanguage { UserSettingsManager.shared.sourceLanguage }

    // MARK: 存储

    /// 活跃 session 令牌（nonisolated，供 serve 循环快速判断是否已被顶替）。
    private nonisolated let state = ServiceState()

    /// 单条请求的看门狗超时（秒）。系统翻译服务卡死时给出明确错误而不是永久挂起。
    nonisolated static let singleRequestTimeout: Duration = .seconds(25)
    nonisolated static let batchRequestTimeout: Duration = .seconds(90)

    private var queue: [TranslationJob] = []
    private var workWaiter: CheckedContinuation<Void, Never>?

    private var singleWaiters: [UUID: PendingRequest<String>] = [:]
    private var batchWaiters: [UUID: PendingRequest<[String]>] = [:]
    /// batchID → 按提交顺序排列的 item id（用于结果回填顺序）
    private var batchItemOrder: [UUID: [UUID]] = [:]
    private var prepareWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init() {}

    // MARK: - 会话生命周期（由无头宿主视图驱动）

    /// 接收 SwiftUI 提供的 session 并长期服务任务队列。
    ///
    /// 只应在 `.translationTask` 的 action 闭包内 await；session 不会离开本函数的隔离域。
    nonisolated public func serve(session: sending TranslationSession) async {
        let token = await beginServing()
        if #available(macOS 26.0, *) {
            await adoptDownloadCapability(session.canRequestDownloads)
        }
        await refreshAvailability()

        while !Task.isCancelled {
            guard let job = await nextJob(token: token) else { break }
            switch job {
            case .single(let id, let text):
                let started = ContinuousClock.now
                do {
                    let response = try await session.translate(text)
                    await completeSingle(id: id,
                                         text: response.targetText,
                                         latency: Self.milliseconds(since: started))
                } catch {
                    await failSingle(id: id, error: error)
                }

            case .batch(let batchID, let items):
                let requests = items.map {
                    TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
                }
                let started = ContinuousClock.now
                do {
                    let responses = try await session.translations(from: requests)
                    var resolved: [UUID: String] = [:]
                    for response in responses {
                        guard let identifier = response.clientIdentifier,
                              let uuid = UUID(uuidString: identifier) else { continue }
                        resolved[uuid] = response.targetText
                    }
                    await completeBatch(batchID: batchID,
                                        resolved: resolved,
                                        latency: Self.milliseconds(since: started))
                } catch {
                    await failBatch(batchID: batchID, error: error)
                }

            case .prepare(let requestID, let restartOnSuccess):
                do {
                    try await session.prepareTranslation()
                    await completePrepare(requestID: requestID, success: true, restart: restartOnSuccess)
                } catch {
                    await completePrepare(requestID: requestID, success: false, restart: false)
                    await noteReadiness(from: error)
                }
            }
        }

        await endServing(token: token)
    }

    /// 宿主视图出现时准备翻译配置（会先解析出系统真正安装的语言对）。
    public func startTranslationTaskIfNeeded() async {
        await refreshAvailability()
        await startOwnSessionIfPossible()
    }

    /// 用系统已安装的语言对 **自行创建会话**（macOS 26+）。
    ///
    /// 为什么不只依赖 `.translationTask`：它依附 SwiftUI 视图生命周期，
    /// 实测在窗口/视图重算时可能不再提供会话，导致 `state.currentToken == nil`，
    /// 用户就会一直看到「翻译引擎正在准备」（但语言包状态却是「已就绪」）。
    /// 自建会话让引擎彻底独立于 UI，缺失时会自动补上。
    @discardableResult
    public func startOwnSessionIfPossible() async -> Bool {
        if state.currentToken != nil { return true }
        await serveOwnSessionIfAvailable()
        return state.currentToken != nil
    }

    /// 需要时创建一个自建会话并交给 `serve` 循环（会话只在同一隔离域内使用）。
    private func serveOwnSessionIfAvailable() async {
        guard #available(macOS 26.0, *) else { return }
        guard state.currentToken == nil else { return }
        guard let pair = await installedPairForOwnSession() else { return }
        // 会话在 nonisolated 上下文内创建并立即交给 serve，绝不跨隔离域传递
        let session = TranslationSession(installedSource: pair.source, target: pair.target)
        await serve(session: session)
    }

    /// 取已安装的语言对（跨隔离域只传 Sendable 的 Locale.Language）。
    private func installedPairForOwnSession() async -> (source: Locale.Language, target: Locale.Language)? {
        if resolvedPair == nil { await refreshAvailability(force: false) }
        guard let pair = resolvedPair, pair.isInstalled else { return nil }
        return (pair.source, pair.target)
    }

    /// 让 `configuration` 与已解析语言对保持一致（首次建立 / 变化时重建）。
    private func syncConfigurationWithResolvedPair() {
        guard let pair = resolvedPair else {
            if configuration == nil {
                configuration = Self.makeConfiguration(pair: nil, sourceLanguage: currentSourceLanguage)
                configurationPairDescription = "default"
            }
            return
        }
        if configuration == nil {
            configuration = Self.makeConfiguration(pair: pair, sourceLanguage: currentSourceLanguage)
            configurationPairDescription = pair.description
            return
        }
        guard configurationPairDescription != pair.description else { return }
        configurationPairDescription = pair.description
        restartTranslationTask()
    }

    @MainActor
    private func adoptDownloadCapability(_ value: Bool) {
        canRequestDownloads = value
    }

    /// 重建 session（离线包安装完成后、或 session 失效后恢复）。
    public func restartTranslationTask() {
        if var current = configuration {
            // version 参与 Equatable：invalidate() 会改变身份 → SwiftUI 重新执行 translationTask
            current.invalidate()
            configuration = current
        } else {
            configuration = Self.makeConfiguration(pair: nil, sourceLanguage: currentSourceLanguage)
        }
    }

    /// 切换全局源语言后，重新探测语言包并重建翻译会话。
    public func refreshForSelectedLanguage() async {
        resolvedPair = nil
        resolvedSourceIdentifier = nil
        readiness = .checking
        configurationPairDescription = nil
        restartTranslationTask()
        await refreshAvailability(force: true)
        if #available(macOS 26.0, *) {
            _ = await startOwnSessionIfPossible()
        }
    }

    /// 用已解析的语言对构造配置；未解析时退回语义默认值（会被随后的解析结果替换）。
    static func makeConfiguration(pair: ResolvedPair?, sourceLanguage: TranslationSourceLanguage = .english) -> TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: pair?.source ?? Locale.Language(identifier: sourceLanguage.rawValue),
            target: pair?.target ?? Locale.Language(identifier: targetLanguageIdentifier)
        )
    }

    public static func makeConfiguration() -> TranslationSession.Configuration {
        makeConfiguration(pair: nil)
    }

    // MARK: - 离线语言包

    /// 面向用户 / 排查的一句话诊断，用于「引擎未就绪」时说明到底卡在哪一步。
    public var diagnostics: String {
        let pairText = resolvedPair.map { "\($0.description)\($0.isInstalled ? "（已安装）" : "（未安装）")" } ?? "未解析到语言对"
        let sessionText = state.currentToken != nil ? "翻译会话已建立（第 \(sessionGeneration) 次）" : "翻译会话未建立"
        return "\(pairText)；\(sessionText)；状态：\(readiness.localizedDescription)"
    }

    /// 解析出真正可用的语言对（优先 `.installed`，否则取第一个 `.supported` 用于引导下载）。
    ///
    /// - Parameter force: 为 true 时丢弃缓存重新探测（用户可能刚在系统设置里装好）。
    @discardableResult
    public func resolveLanguagePair(force: Bool = false) async -> ResolvedPair? {
        let selectedLanguage = currentSourceLanguage
        if !force, resolvedSourceIdentifier == selectedLanguage.rawValue, let resolvedPair { return resolvedPair }
        if resolvedSourceIdentifier != selectedLanguage.rawValue {
            resolvedPair = nil
            resolvedSourceIdentifier = selectedLanguage.rawValue
        }

        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages

        // 注意：必须按 **字面标识符** 组织候选并去重，不能按 maximalIdentifier 去重——
        // 本机实测 Locale.Language(identifier:"en").maximalIdentifier == "en-Latn-GB"，
        // 但 status(from: en, ...) 与 status(from: en-GB, ...) 的结果并不相同
        // （前者按未指定地区处理，判定为「未安装」）。把候选规范化会把可用组合吃掉。
        let sourceIdentifiers = Self.orderedSourceIdentifiers(from: supported, language: selectedLanguage)
        let targetIdentifiers = Self.orderedChineseTargetIdentifiers(from: supported)

        var firstSupported: ResolvedPair?
        for sourceIdentifier in sourceIdentifiers {
            let source = Locale.Language(identifier: sourceIdentifier)
            for targetIdentifier in targetIdentifiers {
                let target = Locale.Language(identifier: targetIdentifier)
                switch await availability.status(from: source, to: target) {
                case .installed:
                    let pair = ResolvedPair(source: source, target: target, isInstalled: true)
                    resolvedPair = pair
                    readiness = .ready
                    return pair
                case .supported:
                    if firstSupported == nil {
                        firstSupported = ResolvedPair(source: source, target: target, isInstalled: false)
                    }
                default:
                    break
                }
            }
        }

        resolvedPair = firstSupported
        return firstSupported
    }

    /// 检查离线包状态；必要时重新解析语言对，并在语言对变化时重建 session。
    ///
    /// - Parameter force: 强制重新探测（应用回到前台、用户点「重译」等场景）。
    public func refreshAvailability(force: Bool = false) async {
        let previousPair = resolvedPair
        let pair = await resolveLanguagePair(force: force)

        guard let pair else {
            readiness = .unsupported(currentSourceLanguage.description)
            return
        }

        readiness = pair.isInstalled ? .ready : .needsDownload

        // 语言对变化（例如用户刚装好 en_GB/zh_CN）→ 重建 session 以采用新的 source/target
        _ = previousPair
        syncConfigurationWithResolvedPair()
    }

    /// 英文源语言候选顺序（按字面标识符去重，确定性、可测试）：
    /// 用户偏好里的英文变体 → en-US → en-GB → 框架枚举的其余变体 → 裸 `en`。
    nonisolated static func orderedEnglishSourceIdentifiers(from supported: [Locale.Language]) -> [String] {
        let variants = supported
            .filter { $0.languageCode?.identifier == "en" }
            .map(\.maximalIdentifier)
        let preferredEnglish = Locale.preferredLanguages
            .first { Locale.Language(identifier: $0).languageCode?.identifier == "en" }

        var ordered: [String] = []
        func append(_ identifier: String) {
            guard !ordered.contains(identifier) else { return }
            ordered.append(identifier)
        }
        if let preferredEnglish { append(preferredEnglish) }
        append("en-US")
        append("en-GB")
        variants.forEach(append)
        append("en")
        return ordered
    }

    nonisolated static func orderedSourceIdentifiers(
        from supported: [Locale.Language],
        language: TranslationSourceLanguage
    ) -> [String] {
        guard language == .japanese else { return orderedEnglishSourceIdentifiers(from: supported) }
        let variants = supported
            .filter { $0.languageCode?.identifier == "ja" }
            .map(\.maximalIdentifier)
        var ordered: [String] = []
        func append(_ identifier: String) {
            guard !ordered.contains(identifier) else { return }
            ordered.append(identifier)
        }
        append("ja-JP")
        append("ja")
        variants.forEach(append)
        return ordered
    }

    /// 简体中文目标候选顺序：zh-Hans → zh-CN → 框架枚举的 Hans 变体 → 裸 `zh`。
    nonisolated static func orderedChineseTargetIdentifiers(from supported: [Locale.Language]) -> [String] {
        let hansVariants = supported
            .filter { $0.languageCode?.identifier == "zh" && ($0.script?.identifier ?? "Hans") == "Hans" }
            .map(\.maximalIdentifier)

        var ordered: [String] = []
        func append(_ identifier: String) {
            guard !ordered.contains(identifier) else { return }
            ordered.append(identifier)
        }
        append("zh-Hans")
        append("zh-CN")
        hansVariants.forEach(append)
        append("zh")
        return ordered
    }

    /// 触发系统下载离线语言包，返回是否安装成功。
    ///
    /// macOS 15 起 `prepareTranslation()` 在语言包缺失时会发起系统下载流程；
    /// 若系统未弹窗（例如用户曾拒绝），UI 应引导用户前往系统设置手动安装。
    public func prepareOfflineLanguagePack() async -> Bool {
        // 先确保语言对已解析：缺包时给出的是「可下载」的那一对（而不是不可用的 en_US）
        let pair = await resolveLanguagePair(force: true)
        guard pair != nil else { return false }
        syncConfigurationWithResolvedPair()
        let success = await runPrepare(restartOnSuccess: true, waitForSessionFirst: true)
        if success { await refreshAvailability(force: true) }
        return success
    }

    /// 语言包已安装时预热翻译引擎（首次翻译同样存在一次性加载成本）。
    ///
    /// 只在 `.ready` 时执行，避免在语言包未安装时触发系统下载弹窗。
    /// 预热完成后 **不** 重建 session。
    @discardableResult
    public func prewarmIfReady() async -> Bool {
        if resolvedPair == nil { await refreshAvailability(force: true) }
        guard readiness == .ready else { return false }
        return await runPrepare(restartOnSuccess: false, waitForSessionFirst: true)
    }

    private func runPrepare(restartOnSuccess: Bool, waitForSessionFirst: Bool) async -> Bool {
        if waitForSessionFirst, !(await waitForSession(timeout: .seconds(6))) { return false }
        let requestID = UUID()
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            prepareWaiters[requestID] = continuation
            enqueue(.prepare(requestID: requestID, restartOnSuccess: restartOnSuccess))
        }
        await refreshAvailability()
        return success
    }

    // MARK: - 翻译（TranslationEngineProtocol）

    public func translate(text: String) async throws -> String {
        let cleaned = cleanedForCurrentLanguage(text)
        guard !cleaned.isEmpty else { return "" }
        guard await ensureEngineReady(timeout: .seconds(4)) else {
            throw engineNotReadyError()
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                singleWaiters[id] = PendingRequest(continuation)
                enqueue(.single(id: id, text: cleaned))
                startWatchdog(id: id, timeout: Self.singleRequestTimeout) { [weak self] in
                    self?.failSingle(id: id, error: Self.watchdogError())
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSingle(id: id)
            }
        }
    }

    public func batchTranslate(texts: [String]) async throws -> [String] {
        let cleaned = texts.map(cleanedForCurrentLanguage)
        var results = cleaned
        let indexed = cleaned.enumerated().filter { !$0.element.isEmpty }
        guard !indexed.isEmpty else { return results }
        guard await ensureEngineReady(timeout: .seconds(6)) else {
            throw engineNotReadyError()
        }

        for chunk in indexed.chunked(into: Self.defaultBatchSize) {
            if Task.isCancelled { throw TranslationServiceError.cancelled }
            let batchID = UUID()
            let items = chunk.map { TranslationJob.Item(id: UUID(), text: $0.element) }

            let translated: [String]
            do {
                translated = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                    batchWaiters[batchID] = PendingRequest(continuation)
                    batchItemOrder[batchID] = items.map(\.id)
                    enqueue(.batch(batchID: batchID, items: items))
                    startWatchdog(id: batchID, timeout: Self.batchRequestTimeout) { [weak self] in
                        self?.failBatch(batchID: batchID, error: Self.watchdogError())
                    }
                }
            } catch {
                // 单块失败：保留原文，让整份文档仍可继续
                continue
            }

            for (offset, value) in translated.enumerated() where offset < chunk.count {
                if !value.isEmpty { results[chunk[offset].offset] = value }
            }
        }
        return results
    }

    /// 严格批量翻译：任一批次失败都会抛出错误，供必须显示真实译文的实时覆盖层使用。
    /// 文档翻译可以保留原文继续处理；常驻翻译则不能把原文伪装成成功译文。
    public func batchTranslateStrict(texts: [String]) async throws -> [String] {
        let cleaned = texts.map(cleanedForCurrentLanguage)
        var results = cleaned
        let indexed = cleaned.enumerated().filter { !$0.element.isEmpty }
        guard !indexed.isEmpty else { return results }
        guard await ensureEngineReady(timeout: .seconds(6)) else {
            throw engineNotReadyError()
        }

        for chunk in indexed.chunked(into: Self.defaultBatchSize) {
            if Task.isCancelled { throw TranslationServiceError.cancelled }
            let batchID = UUID()
            let items = chunk.map { TranslationJob.Item(id: UUID(), text: $0.element) }
            let translated = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<[String], Error>) in
                    batchWaiters[batchID] = PendingRequest(continuation)
                    batchItemOrder[batchID] = items.map(\.id)
                    enqueue(.batch(batchID: batchID, items: items))
                    startWatchdog(id: batchID, timeout: Self.batchRequestTimeout) { [weak self] in
                        self?.failBatch(batchID: batchID, error: Self.watchdogError())
                    }
                })
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelBatch(batchID: batchID)
                }
            }

            for (offset, value) in translated.enumerated() where offset < chunk.count {
                if !value.isEmpty { results[chunk[offset].offset] = value }
            }
        }
        return results
    }

    /// 带进度的批量翻译（PDF 全篇翻译用）。
    public func batchTranslate(
        texts: [String],
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [String] {
        let cleaned = texts.map(cleanedForCurrentLanguage)
        var results = cleaned
        let indexed = cleaned.enumerated().filter { !$0.element.isEmpty }
        guard !indexed.isEmpty else { return results }
        guard await ensureEngineReady(timeout: .seconds(6)) else {
            throw engineNotReadyError()
        }

        var done = 0
        for chunk in indexed.chunked(into: Self.defaultBatchSize) {
            if Task.isCancelled { throw TranslationServiceError.cancelled }
            let batchID = UUID()
            let items = chunk.map { TranslationJob.Item(id: UUID(), text: $0.element) }
            if let translated = try? await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<[String], Error>) in
                batchWaiters[batchID] = PendingRequest(continuation)
                batchItemOrder[batchID] = items.map(\.id)
                enqueue(.batch(batchID: batchID, items: items))
                startWatchdog(id: batchID, timeout: Self.batchRequestTimeout) { [weak self] in
                    self?.failBatch(batchID: batchID, error: Self.watchdogError())
                }
            }) {
                for (offset, value) in translated.enumerated() where offset < chunk.count {
                    if !value.isEmpty { results[chunk[offset].offset] = value }
                }
            }
            done += chunk.count
            onProgress?(done, indexed.count)
        }
        return results
    }

    // MARK: - 队列（MainActor）

    private func enqueue(_ job: TranslationJob) {
        queue.append(job)
        resumeWorkWaiterIfNeeded()
    }

    private func cleanedForCurrentLanguage(_ text: String) -> String {
        if currentSourceLanguage == .japanese {
            return text.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return TextSanitizer.cleanAcademicText(text)
    }

    /// 注册为当前服务者并返回令牌；旧服务者会被唤醒并自行退出。
    private func beginServing() -> Int {
        let token = state.advanceToken()
        sessionGeneration += 1
        resumeWorkWaiterIfNeeded()
        return token
    }

    private func endServing(token: Int) {
        state.releaseIfCurrent(token: token)
        resumeWorkWaiterIfNeeded()
    }

    private func nextJob(token: Int) async -> TranslationJob? {
        while true {
            guard state.currentToken == token else { return nil }
            if !queue.isEmpty { return queue.removeFirst() }
            if Task.isCancelled { return nil }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    workWaiter = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resumeWorkWaiterIfNeeded()
                }
            }
        }
    }

    /// 看门狗：超时仍未完成则主动失败，避免请求永久悬挂。
    private func startWatchdog(id: UUID, timeout: Duration, onTimeout: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            onTimeout()
        }
    }

    nonisolated static func watchdogError() -> TranslationServiceError {
        .underlying(String(localized: "系统翻译服务响应超时（可能正在下载离线语言包）。请稍后重试。"))
    }

    private func resumeWorkWaiterIfNeeded() {
        guard let waiter = workWaiter else { return }
        workWaiter = nil
        waiter.resume()
    }

    // MARK: - 结果回填（MainActor）

    private func completeSingle(id: UUID, text: String, latency: Double) {
        guard let request = singleWaiters.removeValue(forKey: id) else { return }
        completedTranslationCount += 1
        lastLatencyMilliseconds = latency
        readiness = .ready
        request.resume(.success(text))
    }

    private func failSingle(id: UUID, error: Error) {
        guard let request = singleWaiters.removeValue(forKey: id) else { return }
        noteReadiness(from: error)
        request.resume(.failure(mappedError(error)))
    }

    private func cancelSingle(id: UUID) {
        guard let request = singleWaiters.removeValue(forKey: id) else { return }
        request.resume(.failure(TranslationServiceError.cancelled))
    }

    /// Remove a cancelled batch before it reaches TranslationSession. If it is
    /// already executing, discard its eventual result and release the caller now.
    private func cancelBatch(batchID: UUID) {
        guard let request = batchWaiters.removeValue(forKey: batchID) else { return }
        _ = batchItemOrder.removeValue(forKey: batchID)
        queue.removeAll { job in
            guard case .batch(let queuedID, _) = job else { return false }
            return queuedID == batchID
        }
        request.resume(.failure(TranslationServiceError.cancelled))
    }

    private func completeBatch(batchID: UUID, resolved: [UUID: String], latency: Double) {
        guard let request = batchWaiters.removeValue(forKey: batchID) else { return }
        let order = batchItemOrder.removeValue(forKey: batchID) ?? []
        completedTranslationCount += order.count
        lastLatencyMilliseconds = latency
        readiness = .ready
        // 按提交顺序回填；缺失项返回空串，由调用方回退原文
        request.resume(.success(order.map { resolved[$0] ?? "" }))
    }

    private func failBatch(batchID: UUID, error: Error) {
        guard let request = batchWaiters.removeValue(forKey: batchID) else { return }
        _ = batchItemOrder.removeValue(forKey: batchID)
        noteReadiness(from: error)
        request.resume(.failure(mappedError(error)))
    }

    /// prepare 任务的恢复点。`restart` 为真时（用户手动下载离线包）才重建 session。
    private func completePrepare(requestID: UUID, success: Bool, restart: Bool) {
        guard let continuation = prepareWaiters.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: success)
        if success, restart { restartTranslationTask() }
    }

    // MARK: - 就绪等待

    private func ensureEngineReady(timeout: Duration) async -> Bool {
        // 每次真正要用之前都重新确认一次：用户可能刚在系统设置里装好/卸载离线包，
        // 绝不能因为一次历史探测结果就把引擎永久判死。
        if readiness != .ready {
            await refreshAvailability(force: true)
        }
        if state.currentToken == nil {
            // 自愈：会话缺失时立刻补建（macOS 26+），避免出现「包已就绪但引擎在准备」
            await startOwnSessionIfPossible()
        }
        if readiness == .ready, state.currentToken != nil { return true }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(25))
            if state.currentToken != nil, readiness == .ready { return true }
        }
        return false
    }

    /// 仅等待 session 建立，与语言包状态无关（供「下载离线包」入口使用）。
    private func waitForSession(timeout: Duration) async -> Bool {
        if state.currentToken != nil { return true }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(25))
            if state.currentToken != nil { return true }
        }
        return false
    }

    private func engineNotReadyError() -> TranslationServiceError {
        switch readiness {
        case .needsDownload: return .languagePackMissing
        case .unsupported(let pair): return .unsupportedLanguagePair(pair)
        default: return .engineNotReady
        }
    }

    // MARK: - 错误归类

    /// 翻译错误的语义分类。
    ///
    /// 注意：`TranslationError.notInstalled` / `.alreadyCancelled` 只在 macOS 26+ 才有常量，
    /// 而本项目最低支持 macOS 15，因此这里做能力探测 + 状态兜底，保证 15 上同样能
    /// 正确提示「离线语言包未安装」。
    nonisolated enum FailureKind: Sendable {
        case languagePackMissing
        case unsupportedPair
        case engineStale
        case needsInput
        case other
    }

    nonisolated static func classify(_ error: Error) -> FailureKind {
        if TranslationError.nothingToTranslate ~= error { return .needsInput }
        if TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return .unsupportedPair
        }
        if #available(macOS 26.0, *) {
            if TranslationError.notInstalled ~= error { return .languagePackMissing }
            if TranslationError.alreadyCancelled ~= error { return .engineStale }
        }
        if error is CancellationError { return .engineStale }
        return .other
    }

    private func noteReadiness(from error: Error) {
        switch Self.classify(error) {
        case .languagePackMissing:
            readiness = .needsDownload
        case .unsupportedPair:
            readiness = .unsupported(currentSourceLanguage.description)
        case .needsInput, .engineStale, .other:
            // 属于「这一次请求失败」，不污染引擎状态
            break
        }
    }

    private func mappedError(_ error: Error) -> Error {
        if error is TranslationServiceError { return error }
        switch Self.classify(error) {
        case .languagePackMissing:
            return TranslationServiceError.languagePackMissing
        case .unsupportedPair:
            return TranslationServiceError.unsupportedLanguagePair(currentSourceLanguage.description)
        case .engineStale:
            return TranslationServiceError.engineNotReady
        case .needsInput:
            return TranslationServiceError.emptyInput
        case .other:
            // macOS 15 兜底：状态已知缺包时，把这次失败归因为缺包
            if readiness == .needsDownload { return TranslationServiceError.languagePackMissing }
            if error is CancellationError { return TranslationServiceError.cancelled }
            return TranslationServiceError.underlying(error.localizedDescription)
        }
    }

    nonisolated static func milliseconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - instant
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

// MARK: - nonisolated 令牌状态

/// 单次请求的挂起状态；带锁保证「只被恢复一次」。
private final class PendingRequest<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        switch result {
        case .success(let value): pending.resume(returning: value)
        case .failure(let error): pending.resume(throwing: error)
        }
    }
}

/// session 令牌的线程安全容器（供 nonisolated 的 serve 循环快速判断是否已被顶替）。
private final class ServiceState: @unchecked Sendable {
    private let lock = NSLock()
    private var token: Int = 0

    var currentToken: Int? {
        lock.lock(); defer { lock.unlock() }
        return token == 0 ? nil : token
    }

    func advanceToken() -> Int {
        lock.lock(); defer { lock.unlock() }
        token += 1
        return token
    }

    func releaseIfCurrent(token value: Int) {
        lock.lock(); defer { lock.unlock() }
        if token == value { token = 0 }
    }
}

// MARK: - 工具

nonisolated extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
