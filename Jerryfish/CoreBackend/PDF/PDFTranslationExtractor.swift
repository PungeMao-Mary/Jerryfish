import AppKit
import CoreGraphics
import Foundation
import PDFKit

// ============================================================
// PDF 文本提取服务（翻译前的「取词 + 定位」阶段）
//
// 双通道策略：
//   - 矢量 PDF（有文本层、页面未旋转）→ PDFKit `page.selection(for:)` 精确取词 + 精确包围盒
//   - 扫描版 PDF / 旋转页 → 渲染页面位图 → VisionOCRService（坐标天然是显示坐标系）
//
// 输出：段落级文本 + 归一化包围盒（原点左上，与 PDFAnnotationItem 完全一致），
// 因此可以直接映射为「原地译文批注」。
// ============================================================

nonisolated public enum PDFTranslationError: LocalizedError, Sendable {
    case cannotOpen(URL)
    case noPage
    case noText

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url):
            return String(localized: "无法打开 PDF：\(url.lastPathComponent)")
        case .noPage:
            return String(localized: "所选的 PDF 没有可翻译页面。")
        case .noText:
            return String(localized: "未在 PDF 中提取到可翻译文本（可能是纯图片页）。")
        }
    }
}

/// 一段待翻译文本及其在页面上的位置。
nonisolated public struct PDFTextParagraph: Sendable, Equatable {
    public enum Source: String, Sendable {
        case textLayer
        case ocr
    }

    public var pageIndex: Int
    public var text: String
    /// 归一化包围盒（原点左上，0...1）
    public var boundingBox: CGRect
    public var lineCount: Int
    public var source: Source
    public var confidence: Float

    public init(
        pageIndex: Int,
        text: String,
        boundingBox: CGRect,
        lineCount: Int = 1,
        source: Source = .textLayer,
        confidence: Float = 1
    ) {
        self.pageIndex = pageIndex
        self.text = text
        self.boundingBox = boundingBox
        self.lineCount = lineCount
        self.source = source
        self.confidence = confidence
    }
}

/// 中间态：保留**未清洗**的原始行，供「逐页重复」的页眉 / 页脚识别使用。
///
/// 为什么需要：`TextSanitizer` 会把段内换行合并成空格，若在清洗后再按 `\n` 找重复行，
/// 每页重复的页眉就会被漏掉（实测踩到）。因此在清洗前按原始行做剔除。
private struct DraftParagraph {
    var pageIndex: Int
    var rawLines: [String]
    var boundingBox: CGRect
    var source: PDFTextParagraph.Source
    var confidence: Float
}

/// 提取结果。
nonisolated public struct PDFExtractionResult: Sendable {
    public var paragraphs: [PDFTextParagraph]
    /// 每页的 cropBox 尺寸（点），index = pageIndex
    public var pageSizesInPoints: [CGSize]
    /// 走了 OCR 通道的页面
    public var ocrPageIndices: [Int]
    /// 被识别为页眉/页脚而跳过的文本
    public var skippedHeaderFooterTexts: [String]
}

/// 提取范围。
nonisolated public enum PDFPageSelection: Sendable, Equatable {
    case all
    case indices([Int])
    case first(Int)
}

nonisolated public struct PDFExtractionOptions: Sendable {
    public var pages: PDFPageSelection
    /// 扫描页 OCR 的分辨率（长边点数）
    public var ocrLongestEdge: CGFloat
    /// 段落最少字符数（过滤页码、图注编号等碎片）
    public var minimumCharacters: Int
    /// 段落最少字母数
    public var minimumLetters: Int
    /// 出现超过该比例页面上的相同文本视为页眉/页脚并剔除
    public var headerFooterPageRatio: Double

    public init(
        pages: PDFPageSelection = .all,
        ocrLongestEdge: CGFloat = 1800,
        minimumCharacters: Int = 6,
        minimumLetters: Int = 3,
        headerFooterPageRatio: Double = 0.6
    ) {
        self.pages = pages
        self.ocrLongestEdge = ocrLongestEdge
        self.minimumCharacters = minimumCharacters
        self.minimumLetters = minimumLetters
        self.headerFooterPageRatio = headerFooterPageRatio
    }

    public static let `default` = PDFExtractionOptions()
}

nonisolated public struct PDFTextExtractor: Sendable {

    public let ocrService: VisionOCRService
    public let options: PDFExtractionOptions
    public let sourceLanguage: TranslationSourceLanguage

    public init(
        ocrService: VisionOCRService = VisionOCRService(),
        options: PDFExtractionOptions = .default,
        sourceLanguage: TranslationSourceLanguage = .english
    ) {
        self.ocrService = ocrService
        self.options = options
        self.sourceLanguage = sourceLanguage
    }

    // MARK: - 主入口

    /// 仅读取页数（沙盒安全作用域内的轻量查询，避免主线程解析整份文档）。
    @concurrent
    nonisolated public static func pageCount(at url: URL) async -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// 提取文本段落（含定位）。
    @concurrent
    nonisolated public func extract(from url: URL) async throws -> PDFExtractionResult {
        guard let document = PDFDocument(url: url) else {
            throw PDFTranslationError.cannotOpen(url)
        }
        return try await extract(from: document)
    }

    @concurrent
    nonisolated public func extract(from document: PDFDocument) async throws -> PDFExtractionResult {
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw PDFTranslationError.noPage }

        let targets = resolveTargets(pageCount: pageCount)
        guard !targets.isEmpty else { throw PDFTranslationError.noPage }

        var pageSizes = [CGSize](repeating: .zero, count: pageCount)
        for index in 0..<pageCount {
            pageSizes[index] = document.page(at: index)?.bounds(for: .cropBox).size ?? .zero
        }

        var drafts: [DraftParagraph] = []
        var ocrPages: [Int] = []
        var rawLineDictionary: [String: Int] = [:]

        for pageIndex in targets {
            guard let page = document.page(at: pageIndex) else { continue }
            var pageDrafts = textLayerDrafts(page: page, pageIndex: pageIndex)
            if pageDrafts.isEmpty {
                // 无文本层（扫描版）或页面旋转 → OCR 通道
                pageDrafts = (try? await ocrDrafts(page: page, pageIndex: pageIndex)) ?? []
                if !pageDrafts.isEmpty { ocrPages.append(pageIndex) }
            }
            for draft in pageDrafts {
                for line in draft.rawLines {
                    rawLineDictionary[normalizeForMatching(line), default: 0] += 1
                }
            }
            drafts.append(contentsOf: pageDrafts)
        }

        // 页眉 / 页脚剔除：在大多数页面上重复出现的文本行（在清洗前按原始行判断）
        let headerFooterThreshold = max(2, Int(Double(max(1, targets.count)) * options.headerFooterPageRatio))
        let headerFooter = Set(rawLineDictionary.filter { $0.value >= headerFooterThreshold }.keys)
        let (filtered, skipped) = finalize(drafts: drafts, repeated: headerFooter)

        guard !filtered.isEmpty else { throw PDFTranslationError.noText }

        return PDFExtractionResult(
            paragraphs: filtered,
            pageSizesInPoints: pageSizes,
            ocrPageIndices: ocrPages,
            skippedHeaderFooterTexts: Array(skipped).sorted()
        )
    }

    // MARK: - 范围

    nonisolated func resolveTargets(pageCount: Int) -> [Int] {
        switch options.pages {
        case .all:
            return Array(0..<pageCount)
        case .indices(let indices):
            return indices.filter { $0 >= 0 && $0 < pageCount }.sorted()
        case .first(let count):
            return Array(0..<min(max(0, count), pageCount))
        }
    }

    // MARK: - 文本层通道

    /// 使用 PDFKit 文本层精确提取（仅适用于未旋转页面；旋转页交给 OCR 以保证坐标正确）。
    fileprivate nonisolated func textLayerDrafts(page: PDFPage, pageIndex: Int) -> [DraftParagraph] {
        guard page.rotation % 360 == 0 else { return [] }
        let string = page.attributedString?.string ?? page.string ?? ""
        guard !string.isEmpty else { return [] }

        let crop = page.bounds(for: .cropBox)
        guard crop.width > 1, crop.height > 1 else { return [] }

        let nsString = string as NSString
        var lines: [TextBlockGrouper.Line] = []
        var location = 0

        while location < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(lineRange) }
            guard lineRange.length > 0 else { continue }

            let lineText = nsString.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineText.isEmpty else { continue }
            guard let selection = page.selection(for: lineRange) else { continue }

            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, bounds.width > 0.5, bounds.height > 0.5 else { continue }
            guard let normalized = Self.normalize(bounds, cropBox: crop) else { continue }

            lines.append(TextBlockGrouper.Line(text: lineText, boundingBox: normalized))
        }

        guard !lines.isEmpty else { return [] }

        let blocks = TextBlockGrouper.group(
            lines: lines,
            options: .init(lineJoiner: .newline)
        )
        return blocks.map { block in
            DraftParagraph(
                pageIndex: pageIndex,
                rawLines: block.text.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                boundingBox: block.boundingBox,
                source: .textLayer,
                confidence: block.averageConfidence
            )
        }
    }

    // MARK: - OCR 通道

    fileprivate nonisolated func ocrDrafts(page: PDFPage, pageIndex: Int) async throws -> [DraftParagraph] {
        let crop = page.bounds(for: .cropBox)
        let longest = max(crop.width, crop.height)
        guard longest > 1 else { return [] }

        let scale = max(1.0, min(4.0, options.ocrLongestEdge / longest))
        let renderSize = CGSize(width: crop.width * scale, height: crop.height * scale)

        let thumbnail = page.thumbnail(of: renderSize, for: .cropBox)
        guard let cgImage = Self.rasterize(thumbnail) else { return [] }
        // 不做降采样：预热后的 Vision 识别耗时与分辨率基本无关（实测 110~130ms），
        // 保留全部像素对扫描版小字号文本的识别精度更有利。
        let result = try await ocrService.recognize(cgImage: cgImage)
        return result.blocks.map { block in
            DraftParagraph(
                pageIndex: pageIndex,
                rawLines: block.text.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                boundingBox: block.boundingBox,
                source: .ocr,
                confidence: block.averageConfidence
            )
        }
    }

    // MARK: - 过滤

    nonisolated func passesFilter(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimumCharacters = sourceLanguage == .japanese ? min(2, options.minimumCharacters) : options.minimumCharacters
        let minimumLetters = sourceLanguage == .japanese ? 1 : options.minimumLetters
        guard trimmed.count >= minimumCharacters else { return false }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= minimumLetters else { return false }
        // 纯页码 / 纯数字行
        if trimmed.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isWhitespace }) { return false }
        // "Page 3 of 12" / "1324" 之类
        if trimmed.range(of: #"^[Pp]age\s*\d+"#, options: .regularExpression) != nil,
           trimmed.count < 20 { return false }
        return true
    }

    /// 草稿 → 最终段落：剔除逐页重复的行，再对剩余内容做学术清洗。
    ///
    /// 顺序很关键：必须在**清洗前**按原始行剔除，否则段内换行已被合并成空格，
    /// 每页重复的页眉就再也认不出来了。
    fileprivate nonisolated func finalize(
        drafts: [DraftParagraph],
        repeated: Set<String>
    ) -> ([PDFTextParagraph], Set<String>) {
        var kept: [PDFTextParagraph] = []
        var skipped: Set<String> = []
        for draft in drafts {
            var remaining = draft.rawLines
            if !repeated.isEmpty {
                let hits = remaining.filter { repeated.contains(normalizeForMatching($0)) }
                if !hits.isEmpty {
                    skipped.formUnion(hits)
                    remaining = remaining.filter { !repeated.contains(normalizeForMatching($0)) }
                }
            }
            guard !remaining.isEmpty else { continue }
            let rawText = remaining.joined(separator: "\n")
            let text = sourceLanguage == .japanese
                ? rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                : TextSanitizer.cleanAcademicText(rawText)
            guard passesFilter(text) else { continue }
            kept.append(PDFTextParagraph(
                pageIndex: draft.pageIndex,
                text: text,
                boundingBox: draft.boundingBox,
                lineCount: remaining.count,
                source: draft.source,
                confidence: draft.confidence
            ))
        }
        return (kept, skipped)
    }

    nonisolated func normalizeForMatching(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    // MARK: - 几何

    /// PDF 页面空间（原点左下）→ 归一化（原点左上）。
    nonisolated static func normalize(_ rect: CGRect, cropBox: CGRect) -> CGRect? {
        guard cropBox.width > 0.5, cropBox.height > 0.5 else { return nil }
        let clamped = rect.standardized.intersection(cropBox)
        guard !clamped.isNull, clamped.width > 0.3, clamped.height > 0.3 else { return nil }
        let normalized = CGRect(
            x: (clamped.minX - cropBox.minX) / cropBox.width,
            y: (cropBox.maxY - clamped.maxY) / cropBox.height,
            width: clamped.width / cropBox.width,
            height: clamped.height / cropBox.height
        )
        return normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// NSImage → CGImage（优先取底层位图，失败则重绘）。
    nonisolated static func rasterize(_ image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return cgImage
        }
        let width = max(1, Int(image.size.width.rounded()))
        let height = max(1, Int(image.size.height.rounded()))
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
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
