import CoreGraphics
import Translation
import Vision
import XCTest
@testable import Jerryfish

// ============================================================
// 语言对解析 + 真实翻译链路 + 截屏就地译文映射
//
// 这些用例覆盖了「明明装了离线包却提示未安装」那个缺陷的回归面：
//   - 不能把语言标识写死成裸 "en"（framework 会解析成 en-Latn-US）
//   - 必须按系统实际安装的变体（可能是 en-GB + zh-CN）解析出可用语言对
// ============================================================

/// 需要「真实 OCR / 真实翻译引擎」的用例开关。
///
/// 默认关闭：这些用例会启动真实模型（冷启动可能 20s+）并要求 app 宿主提供翻译会话，
/// 会让 `xcodebuild test` 长时间挂着、弹出应用窗口。需要时显式打开：
/// `JERRYFISH_LIVE_ENGINE_TESTS=1 xcodebuild ... test`
enum LiveEngineTests {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["JERRYFISH_LIVE_ENGINE_TESTS"] == "1"
    }
}

final class LanguagePairResolutionTests: XCTestCase {

    func testEnglishSourceOrderingIsDeterministic() {
        let supported = [
            Locale.Language(identifier: "en-US"),
            Locale.Language(identifier: "en-GB"),
            Locale.Language(identifier: "ja-JP"),
            Locale.Language(identifier: "fr-FR"),
        ]
        let identifiers = TranslationService.orderedEnglishSourceIdentifiers(from: supported)

        XCTAssertFalse(identifiers.contains(where: { $0.hasPrefix("ja") || $0.hasPrefix("fr") }),
                       "候选源语言只能是英文：\(identifiers)")
        XCTAssertTrue(identifiers.contains("en-US"))
        XCTAssertTrue(identifiers.contains("en-GB"))
        XCTAssertTrue(identifiers.contains("en-Latn-GB"))
        // en-US 必须排在 en-GB 之前（经典默认），且裸 en 最后（必须保留，语义与带地区写法不同）
        let us = try! XCTUnwrap(identifiers.firstIndex(of: "en-US"))
        let gb = try! XCTUnwrap(identifiers.firstIndex(of: "en-GB"))
        XCTAssertLessThan(us, gb)
        XCTAssertEqual(identifiers.last, "en")
    }

    func testChineseTargetOrderingOnlyContainsSimplified() {
        let supported = [
            Locale.Language(identifier: "zh-Hant-TW"),
            Locale.Language(identifier: "zh-Hans-CN"),
            Locale.Language(identifier: "ja-JP"),
        ]
        let identifiers = TranslationService.orderedChineseTargetIdentifiers(from: supported)

        XCTAssertFalse(identifiers.contains(where: { $0.contains("Hant") }),
                       "目标候选不应包含繁体：\(identifiers)")
        XCTAssertTrue(identifiers.contains("zh-Hans"))
        XCTAssertTrue(identifiers.contains("zh-CN"))
        XCTAssertTrue(identifiers.contains("zh-Hans-CN"))
        XCTAssertEqual(identifiers.last, "zh")
    }

    /// 真实探测系统资产：必须解析出「英语 → 简体中文」的某个变体，
    /// 且只要系统装了包，就一定要判定为 installed（而不是 supported）。
    func testResolvesUsablePairOnThisMachine() async throws {
        let service = TranslationService()
        let pair = await service.resolveLanguagePair(force: true)
        let resolved = try XCTUnwrap(pair, "应至少解析出一个 en→zh 候选语言对")
        XCTAssertEqual(resolved.source.languageCode?.identifier, "en",
                       "源语言必须是英语，实际：\(resolved.description)")
        XCTAssertEqual(resolved.target.languageCode?.identifier, "zh",
                       "目标语言必须是中文，实际：\(resolved.description)")

        // 本机已安装 en_GB + zh_CN；若未安装则跳过（换机器不会误报失败）
        try XCTSkipUnless(resolved.isInstalled, "本机未安装 en→zh 离线包（解析结果 \(resolved.description)）")
        XCTAssertEqual(service.readiness, .ready)
        XCTAssertNotEqual(resolved.source.maximalIdentifier, "en-Latn-US",
                          "不能把裸 en 解析成 en-US 后就直接使用")
    }

    /// 端到端：把真实 session 交给 TranslationService，走完整队列链路实译一句话。
    func testEndToEndTranslationThroughServiceQueue() async throws {
        try XCTSkipUnless(LiveEngineTests.enabled, "需要真实引擎：设置 JERRYFISH_LIVE_ENGINE_TESTS=1 后运行")
        guard #available(macOS 26.0, *) else { throw XCTSkip("installedSource 初始化需要 macOS 26+") }

        let service = TranslationService()
        await service.refreshAvailability(force: true)
        let pair = try XCTUnwrap(service.resolvedPair, "应解析出语言对")
        try XCTSkipUnless(pair.isInstalled, "本机未安装离线包，跳过实译（\(pair.description)）")

        let session = TranslationSession(installedSource: pair.source, target: pair.target)
        let serving = Task { await service.serve(session: session) }
        defer { serving.cancel() }

        let translated = try await service.translate(text: "The results show a dose-dependent effect.")
        XCTAssertTrue(translated.contains("剂量") || translated.contains("依赖"),
                      "译文应包含剂量依赖性相关内容，实际：\(translated)")
        XCTAssertGreaterThan(service.completedTranslationCount, 0)
    }

    /// 裸 "en" 仍然要能工作（内部会解析成已安装变体），不应因变体不匹配而失败。
    func testBareEnglishIdentifierStillWorks() async throws {
        try XCTSkipUnless(LiveEngineTests.enabled, "需要真实引擎：设置 JERRYFISH_LIVE_ENGINE_TESTS=1 后运行")
        guard #available(macOS 26.0, *) else { throw XCTSkip("需要 macOS 26+") }
        let service = TranslationService()
        await service.refreshAvailability(force: true)
        guard let pair = service.resolvedPair, pair.isInstalled else {
            throw XCTSkip("本机未安装离线包")
        }
        let session = TranslationSession(installedSource: pair.source, target: pair.target)
        let serving = Task { await service.serve(session: session) }
        defer { serving.cancel() }

        // batchTranslate 也要走通（PDF / 截屏都依赖它）
        let results = try await service.batchTranslate(texts: ["First paragraph.", "Second paragraph."])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.isEmpty })
    }
}

// ============================================================
// 截屏就地译文映射（不依赖 UI 与语言包）
// ============================================================

@MainActor
final class CaptureBlockLayoutTests: XCTestCase {

    private func makeOCR(blocks: [(String, CGRect, Int)]) -> OCRResult {
        let lineBlocks = blocks.map {
            TextBlockGrouper.Block(text: $0.0, boundingBox: $0.1, lineCount: $0.2, averageConfidence: 1)
        }
        return OCRResult(lines: [], blocks: lineBlocks, text: "", rawText: "",
                         averageConfidence: 1, durationMilliseconds: 0)
    }

    func testNormalizedBoxesMapIntoSelection() {
        let selection = CGRect(x: 200, y: 100, width: 600, height: 400)
        let ocr = makeOCR(blocks: [("First paragraph.", CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05), 2)])
        let blocks = CaptureBlockLayout.makeBlocks(ocr: ocr, translations: ["第一段。"], selection: selection)

        XCTAssertEqual(blocks.count, 1)
        let rect = try! XCTUnwrap(blocks.first).rect
        // 0.1*600+200 = 260，0.2*400+100 = 180；再各向外扩 2 / 1.5
        XCTAssertEqual(rect.minX, 258, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 178.5, accuracy: 0.01)
        XCTAssertEqual(rect.width, 0.5 * 600 + 4, accuracy: 0.01)
        XCTAssertEqual(rect.height, 0.05 * 400 + 3, accuracy: 0.01)
    }

    func testCoverRectFullyCoversSourceBox() {
        let selection = CGRect(x: 0, y: 0, width: 800, height: 600)
        let source = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.08)
        let ocr = makeOCR(blocks: [("Source text here.", source, 3)])
        let blocks = CaptureBlockLayout.makeBlocks(ocr: ocr, translations: ["这是译文。"], selection: selection)

        let cover = try! XCTUnwrap(blocks.first).rect
        let original = CGRect(x: source.minX * 800, y: source.minY * 600,
                              width: source.width * 800, height: source.height * 600)
        XCTAssertTrue(cover.contains(original), "纯色底必须完全盖住原文：cover=\(cover) original=\(original)")
    }

    func testEmptyTranslationsAreSkipped() {
        let selection = CGRect(x: 0, y: 0, width: 500, height: 400)
        let ocr = makeOCR(blocks: [
            ("Alpha.", CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05), 1),
            ("Beta.", CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.05), 1),
        ])
        let blocks = CaptureBlockLayout.makeBlocks(ocr: ocr, translations: ["甲。", "   "], selection: selection)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.text, "甲。")
    }

    func testLongTranslationShrinksFontInsteadOfOverflowing() {
        let selection = CGRect(x: 0, y: 0, width: 600, height: 500)
        let box = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.03)   // 很扁的一段
        let ocr = makeOCR(blocks: [("A short line.", box, 1)])
        let long = String(repeating: "这是一段很长的中文译文用于验证字号收敛。", count: 4)
        let blocks = CaptureBlockLayout.makeBlocks(ocr: ocr, translations: [long], selection: selection)

        let block = try! XCTUnwrap(blocks.first)
        // 字号必须 ≤ 覆盖框高度，行数必须与推算一致，且不需要迭代排版
        XCTAssertLessThanOrEqual(block.fontSize, block.rect.height + 0.01)
        XCTAssertGreaterThanOrEqual(block.fontSize, 7)
        XCTAssertGreaterThan(block.lineCount, 1)
    }

    func testEstimatedLinesIsCheapAndMonotonic() {
        let wide = CaptureBlockLayout.estimatedLines(characters: 100, availableWidth: 400, font: 10)
        let narrow = CaptureBlockLayout.estimatedLines(characters: 100, availableWidth: 100, font: 10)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertEqual(CaptureBlockLayout.estimatedLines(characters: 0, availableWidth: 400, font: 10), 1)
        XCTAssertEqual(CaptureBlockLayout.estimatedLines(characters: 10, availableWidth: 0, font: 0), 1)
    }
}

// ============================================================
// OCR 首次识别延迟回归测试
//
// 背景：Vision 在 **不显式指定 revision** 时会先做一次版本/资产协商，
// 本机实测首次识别要 23 秒（用户体感为「一直在准备 / 延时很高」）。
// 显式指定已安装的 revision 后，同样的模型与结果只需约 0.1 秒。
// 这个用例就是防止该优化被回退。
// ============================================================

final class OCRFirstCallLatencyTests: XCTestCase {

    func testNewestSupportedRevisionIsExplicitlyAvailable() {
        let revision = VisionOCRService.newestSupportedRevision()
        XCTAssertGreaterThanOrEqual(revision, VNRecognizeTextRequestRevision2,
                                    "必须能拿到一个可显式指定的 revision")
        XCTAssertTrue(VNRecognizeTextRequest.supportedRevisions.contains(revision),
                      "返回的 revision 必须在系统支持列表里")
    }

    /// 稳态延迟：预热后的识别必须是毫秒级。
    ///
    /// 注意不能断言「第一个进程的首次调用」很快：那是**模型从冷磁盘载入**的成本
    /// （本机实测约 23 秒，且与 revision 无关；磁盘缓存热了之后任何 revision 都只要 ~100ms）。
    /// App 的做法是启动时后台 `warmUp()` 把这笔成本提前付掉。
    func testSteadyStateRecognitionIsFast() async throws {
        try XCTSkipUnless(LiveEngineTests.enabled, "需要真实 OCR：设置 JERRYFISH_LIVE_ENGINE_TESTS=1 后运行")
        guard let image = VisionOCRService.makeWarmUpImage() else {
            throw XCTSkip("无法生成合成图")
        }
        let service = VisionOCRService()

        // 先热身（允许很慢），再测稳态
        _ = try? await service.recognize(cgImage: image)

        let started = ContinuousClock.now
        let result = try await service.recognize(cgImage: image)
        let elapsed = TranslationService.milliseconds(since: started)

        XCTAssertLessThan(elapsed, 1000, "预热后的识别应 < 1s，实际 \(Int(elapsed))ms")
        XCTAssertGreaterThan(result.durationMilliseconds, 0)
        XCTAssertFalse(result.text.isEmpty)
    }
}
