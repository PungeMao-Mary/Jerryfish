import CoreGraphics
import CoreText
import Foundation
import Vision

// ============================================================
// 毫秒级 OCR 引擎（Vision.framework / VNRecognizeTextRequest）
//
// 设计要点：
//   - `@concurrent`：强制在协作线程池执行，绝不占用主线程（保护 UI 帧率）。
//   - 识别级别固定 `.accurate`，语言默认 `["en-US"]`（本项目只做 en → zh-Hans）。
//   - 输出「双通道」结果：
//       * `lines`：结构化逐行结果 + 归一化 CGRect（原点左上），供原地批注定位
//       * `blocks`：按版面聚合的段落（含并集包围盒），供整段翻译
//       * `text`：清洗后的合并文本，供大输入框直接使用
// ============================================================

nonisolated public enum OCRError: LocalizedError, Sendable {
    case invalidImage
    case engineUnavailable(String)
    case noTextFound

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return String(localized: "截图数据无效，无法识别文字。")
        case .engineUnavailable(let reason):
            return String(localized: "OCR 引擎不可用：\(reason)")
        case .noTextFound:
            return String(localized: "未在所选区域识别到文字。")
        }
    }
}

/// 单行 OCR 结果。
nonisolated public struct OCRLine: Sendable, Equatable {
    public var text: String
    public var confidence: Float
    /// 归一化包围盒：原点左上，相对输入图像，取值 0...1。
    public var boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// 一次 OCR 的完整结果。
nonisolated public struct OCRResult: Sendable {
    /// 逐行结构化结果（已按阅读顺序排序，坐标原点左上）
    public var lines: [OCRLine]
    /// 段落级文本块（含并集包围盒，可直接映射为批注框）
    public var blocks: [TextBlockGrouper.Block]
    /// 清洗后的合并文本（段落之间为 `\n\n`）
    public var text: String
    /// 未清洗的原始合并文本
    public var rawText: String
    /// 平均置信度
    public var averageConfidence: Float
    /// 纯 OCR 耗时（毫秒）
    public var durationMilliseconds: Double

    public static let empty = OCRResult(
        lines: [], blocks: [], text: "", rawText: "",
        averageConfidence: 0, durationMilliseconds: 0
    )
}

nonisolated public struct VisionOCRService: Sendable {

    public enum RecognitionLevel: Sendable {
        case accurate
        case fast

        var visionLevel: VNRequestTextRecognitionLevel {
            switch self {
            case .accurate: return .accurate
            case .fast: return .fast
            }
        }
    }

    public struct Configuration: Sendable {
        /// 识别语言，按优先级排序。学术英文场景固定 `["en-US"]`。
        public var languages: [String]
        public var recognitionLevel: RecognitionLevel
        public var usesLanguageCorrection: Bool
        public var customWords: [String]
        /// 自动脚本/语种检测（revision 3+）。固定英文学术识别建议关闭以获得更稳定的结果。
        public var automaticallyDetectsLanguage: Bool
        /// 最小文本高度（相对图像高度的比例）。0 表示不限制。
        public var minimumTextHeight: Float
        /// 强制指定识别 revision。
        ///
        /// ⚠️ 不要留空：Vision 在 **未显式指定 revision** 时会先做一次版本/资产协商，
        /// 本机实测每次进程首次识别要等约 **23 秒**；显式指定已安装的 revision 后
        /// 首次识别只需 **0.1 秒**（同样的模型、同样的结果）。nil = 自动取最新已安装版本。
        public var revision: Int?
        public var grouping: TextBlockGrouper.Options

        public init(
            languages: [String] = ["en-US"],
            recognitionLevel: RecognitionLevel = .accurate,
            usesLanguageCorrection: Bool = true,
            customWords: [String] = [],
            automaticallyDetectsLanguage: Bool = false,
            minimumTextHeight: Float = 0,
            revision: Int? = nil,
            grouping: TextBlockGrouper.Options = .default
        ) {
            self.languages = languages
            self.recognitionLevel = recognitionLevel
            self.usesLanguageCorrection = usesLanguageCorrection
            self.customWords = customWords
            self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
            self.minimumTextHeight = minimumTextHeight
            self.revision = revision
            self.grouping = grouping
        }

        public static let academicEnglish = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .academicEnglish) {
        self.configuration = configuration
    }

    // MARK: - 公开 API

    /// 识别图像中的文本（结构化 + 合并文本）。
    @concurrent
    nonisolated public func recognize(cgImage: CGImage) async throws -> OCRResult {
        let started = DispatchTime.now()
        let lines = try Self.performRecognition(cgImage: cgImage, configuration: configuration)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000

        let blocks = TextBlockGrouper.group(lines: lines.map {
            TextBlockGrouper.Line(text: $0.text, boundingBox: $0.boundingBox, confidence: $0.confidence)
        }, options: configuration.grouping)

        let rawText = blocks.map(\.text).joined(separator: "\n\n")
        let cleaned: String
        if configuration.languages.first?.hasPrefix("ja") == true {
            cleaned = rawText.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            cleaned = TextSanitizer.cleanAcademicText(rawText)
        }

        let average = lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Float(lines.count)

        return OCRResult(
            lines: lines,
            blocks: blocks,
            text: cleaned,
            rawText: rawText,
            averageConfidence: average,
            durationMilliseconds: elapsed
        )
    }

    /// 预热 OCR 引擎。
    ///
    /// ⚠️ macOS 26/27 的 Vision 文字识别使用按需加载的模型资产，**首次**调用会付出
    /// 一次性的模型加载 / 编译成本。本机实测：
    ///   - 冷启动首次识别：**约 24 秒**（与图像大小无关）
    ///   - 预热后识别：**110 ~ 130 毫秒**（1200px ~ 5120px 均如此）
    ///
    /// 因此必须在 App 启动后立刻在后台预热，否则用户第一次按 ⌘⇧A 会长时间空等。
    @concurrent
    nonisolated public func warmUp() async -> Bool {
        guard let image = Self.makeWarmUpImage() else { return false }
        do {
            _ = try Self.performRecognition(cgImage: image, configuration: configuration)
        } catch OCRError.noTextFound {
            // 引擎已跑通，只是这张合成图没识别出文本
            return true
        } catch {
            return false
        }
        return true
    }

    /// 生成一张带文字的极小合成图，用于预热（纯内存，无任何磁盘 / 网络 IO）。
    nonisolated static func makeWarmUpImage() -> CGImage? {
        let width = 360
        let height = 90
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 只用 CoreText 的 CF 属性键，避免后端模块依赖 AppKit
        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        guard let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            "Warm up 1234" as CFString,
            attributes as CFDictionary
        ) else { return nil }

        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 10, y: 30)
        CTLineDraw(line, context)

        return context.makeImage()
    }

    /// 便捷入口：只要清洗后的纯文本。
    @concurrent
    nonisolated public func recognizeText(cgImage: CGImage) async throws -> String {
        try await recognize(cgImage: cgImage).text
    }

    /// 便捷入口：直接对屏幕区域截图并识别。
    @concurrent
    nonisolated public func recognizeScreenRegion(
        _ rect: CGRect,
        excludingWindowNumbers: Set<Int> = []
    ) async throws -> (result: OCRResult, image: CGImage) {
        let image = try await ScreenCaptureService.captureRegion(
            rect,
            excludingWindowNumbers: excludingWindowNumbers
        )
        let result = try await recognize(cgImage: image)
        return (result, image)
    }

    // MARK: - Vision 调用

    /// 同步执行 Vision 识别（由 `recognize` 在协作线程池上调用）。
    nonisolated static func performRecognition(
        cgImage: CGImage,
        configuration: Configuration
    ) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = configuration.recognitionLevel.visionLevel
        request.recognitionLanguages = configuration.languages
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        if !configuration.customWords.isEmpty {
            request.customWords = configuration.customWords
        }
        if configuration.automaticallyDetectsLanguage {
            request.automaticallyDetectsLanguage = true
        }
        if configuration.minimumTextHeight > 0 {
            request.minimumTextHeight = configuration.minimumTextHeight
        }
        // 显式钉住 revision：跳过 Vision 的版本协商（本机实测 23s → 0.1s）。
        if let revision = configuration.revision {
            request.revision = revision
        } else {
            request.revision = Self.newestSupportedRevision()
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.engineUnavailable(error.localizedDescription)
        }

        let observations = request.results ?? []
        var lines: [OCRLine] = []
        lines.reserveCapacity(observations.count)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(OCRLine(
                text: trimmed,
                confidence: candidate.confidence,
                boundingBox: topLeftNormalizedRect(from: observation.boundingBox)
            ))
        }

        guard !lines.isEmpty else { throw OCRError.noTextFound }
        return sortReadingOrder(lines)
    }

    /// 当前系统支持的最新文字识别 revision（显式指定以避免版本协商开销）。
    nonisolated static func newestSupportedRevision() -> Int {
        let supported = VNRecognizeTextRequest.supportedRevisions
        return supported.max() ?? VNRecognizeTextRequestRevision3
    }

    /// Vision 的 `boundingBox` 为「归一化 + 原点左下」；本项目统一使用「原点左上」。
    static func topLeftNormalizedRect(from visionRect: CGRect) -> CGRect {
        let clamped = visionRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull else { return .zero }
        return CGRect(
            x: clamped.minX,
            y: 1 - clamped.maxY,
            width: clamped.width,
            height: clamped.height
        )
    }

    /// 阅读顺序排序：先上后下，同一行内先左后右。
    static func sortReadingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        lines.sorted { lhs, rhs in
            let dy = lhs.boundingBox.minY - rhs.boundingBox.minY
            let tolerance = min(lhs.boundingBox.height, rhs.boundingBox.height) * 0.5
            if abs(dy) > tolerance { return dy < 0 }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }
}

// MARK: - 图像工具

nonisolated public enum ImageGeometry {

    /// 将 CGImage 等比缩放到长边不超过 `maxDimension`，用于降低 OCR 输入分辨率。
    public static func downscale(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxDimension, longest > 0 else { return image }

        let scale = maxDimension / longest
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    /// 放大长边到 `targetLongestEdge`（扫描版 PDF 页面 OCR 前提升小字可读性）。
    public static func upscale(_ image: CGImage, targetLongestEdge: CGFloat) -> CGImage {
        let longest = max(CGFloat(image.width), CGFloat(image.height))
        guard longest > 0 else { return image }
        return downscale(image, maxDimension: max(targetLongestEdge, longest))
    }
}
