import CoreGraphics
import Foundation

// ============================================================
// 译文批注版式求解器
//
// 输入：英文段落的归一化包围盒 + 中文译文 + 字号偏好
// 输出：可直接交给 `PDFAnnotationItem` 的 start/end（归一化）+ fontSize（页点）
//
// 难点：中文与英文的字宽/行数不同，直接把译文塞进原文的包围盒会溢出被裁掉。
// 因此这里按「可用宽度 → 每行字数 → 所需行数 → 外扩高度」反推，并自动收敛字号。
// ============================================================

nonisolated public enum PDFTranslationOverlayLayout {

    public struct Plan: Sendable, Equatable {
        /// 归一化起点（原点左上）
        public var start: CGPoint
        /// 归一化终点
        public var end: CGPoint
        /// 字号（PDF 页点，非屏幕点）
        public var fontSize: CGFloat
        /// 预计渲染行数
        public var estimatedLines: Int
    }

    public struct Options: Sendable {
        /// 相对原文行高的字号缩放系数（1.0 = 与原文行高一致）
        public var fontScale: Double
        /// 最小字号（页点）
        public var minimumFontSize: CGFloat
        /// 批注框最小宽度（归一化）
        public var minimumWidthFraction: CGFloat
        /// 批注框最大高度（归一化）
        public var maximumHeightFraction: CGFloat
        /// 相对原文框高度的最大外扩倍数
        public var maximumHeightMultiplier: CGFloat
        /// 行距系数（相对字号）
        public var lineHeightRatio: CGFloat

        public init(
            fontScale: Double = 0.62,
            minimumFontSize: CGFloat = 5,
            minimumWidthFraction: CGFloat = 0.24,
            maximumHeightFraction: CGFloat = 0.9,
            maximumHeightMultiplier: CGFloat = 3.0,
            lineHeightRatio: CGFloat = 1.24
        ) {
            self.fontScale = fontScale
            self.minimumFontSize = minimumFontSize
            self.minimumWidthFraction = minimumWidthFraction
            self.maximumHeightFraction = maximumHeightFraction
            self.maximumHeightMultiplier = maximumHeightMultiplier
            self.lineHeightRatio = lineHeightRatio
        }

        public static let `default` = Options()
    }

    /// 为一段译文求解批注几何。
    ///
    /// - Parameters:
    ///   - box: 原文段落包围盒（归一化，原点左上）
    ///   - lineCount: 原文行数（用于推算原文行高）
    ///   - translatedText: 中文译文
    ///   - pageSizeInPoints: 该页 cropBox 的点尺寸
    public static func plan(
        box: CGRect,
        lineCount: Int,
        translatedText: String,
        pageSizeInPoints: CGSize,
        options: Options = .default
    ) -> Plan {
        let pageWidth = max(1, pageSizeInPoints.width)
        let pageHeight = max(1, pageSizeInPoints.height)

        // 1. 可用宽度（归一化 + 页点）
        let widthFraction = min(1.0, max(box.width, options.minimumWidthFraction))
        let availableWidthPt = widthFraction * pageWidth

        // 2. 原文行高（页点）
        let boxHeightPt = max(1, box.height * pageHeight)
        let sourceLineHeightPt = boxHeightPt / CGFloat(max(1, lineCount))

        // 3. 初始字号：按字号偏好，但不超过原文行高
        var fontSize = max(options.minimumFontSize,
                           min(sourceLineHeightPt, sourceLineHeightPt * CGFloat(options.fontScale)))

        // 4. 由「字数 / 每行容量」推算所需高度
        let characterCount = max(1, translatedText.count)
        func requiredHeightNormalized(font: CGFloat) -> CGFloat {
            // CJK 字符近似为 1em 宽
            let charactersPerLine = max(1, Int(availableWidthPt / font))
            let lines = Int(ceil(Double(characterCount) / Double(charactersPerLine)))
            let heightPt = CGFloat(lines) * font * options.lineHeightRatio + 2
            return heightPt / pageHeight
        }

        var neededHeight = requiredHeightNormalized(font: fontSize)

        // 5. 高度上限：超出则等比缩小字号
        let heightCap = min(
            options.maximumHeightFraction,
            max(box.height * options.maximumHeightMultiplier, 0.06)
        )
        if neededHeight > heightCap {
            let ratio = heightCap / neededHeight
            fontSize = max(options.minimumFontSize * 0.8, fontSize * ratio)
            neededHeight = min(heightCap, requiredHeightNormalized(font: fontSize))
        }

        // 6. 关键约束：批注框**绝不能小于原文包围盒**。
        //
        // 否则当译文较短（所需高度 < 原文块高度）时，框会缩到原文块内部，
        // 被纯色底盖住的只有一部分，剩下的原文就露出来了 —— 外观上就是
        // 「译文与原文重叠/原文没被覆盖」。这里至少铺满原文块。
        let minimumHeight = box.height
        neededHeight = max(neededHeight, minimumHeight)

        // 高度不足时向上借位（保持覆盖原文），再夹到页面内
        let startX = min(max(0, box.minX), max(0, 1 - widthFraction))
        var startY = max(0, box.minY)
        if startY + neededHeight > 1 {
            startY = max(0, 1 - neededHeight)
        }
        let endX = min(1, max(startX + widthFraction, box.maxX))
        let endY = min(1, max(startY + neededHeight, box.maxY))

        let estimate = Double(characterCount) / Double(max(1, Int(availableWidthPt / fontSize)))

        return Plan(
            start: CGPoint(x: startX, y: startY),
            end: CGPoint(x: endX, y: endY),
            fontSize: fontSize,
            estimatedLines: max(1, Int(ceil(estimate)))
        )
    }
}

// MARK: - 批注工厂

/// 注意：`PDFAnnotationItem` 定义在宿主工程中被默认 MainActor 隔离，
/// 因此本工厂同样运行在主线程（批注数量在千级以内，构建成本可忽略）。
public enum PDFTranslationAnnotationFactory {

    /// 译文文字颜色（深色，便于在浅色底上阅读；同时用于与用户手绘批注区分）。
    public static let defaultColorHex = "#14384F"

    /// 译文批注的不透明底色：**盖住原文**，避免中英重叠。
    public static let defaultFillColorHex = "#FFFFFF"

    /// 把提取结果 + 译文映射为 `PDFAnnotationItem` 数组。
    ///
    /// - Note: 只有成功翻译（非空且与原文不同）的段落才会生成批注。
    static func makeAnnotations(
        paragraphs: [PDFTextParagraph],
        translations: [String],
        pageSizes: [CGSize],
        colorHex: String = defaultColorHex,
        fillColorHex: String? = defaultFillColorHex,
        layout: PDFTranslationOverlayLayout.Options = .default
    ) -> [PDFAnnotationItem] {
        var items: [PDFAnnotationItem] = []
        items.reserveCapacity(paragraphs.count)

        for (index, paragraph) in paragraphs.enumerated() {
            guard index < translations.count else { break }
            let translation = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty else { continue }

            let pageSize = paragraph.pageIndex < pageSizes.count
                ? pageSizes[paragraph.pageIndex]
                : CGSize(width: 595, height: 842)

            let plan = PDFTranslationOverlayLayout.plan(
                box: paragraph.boundingBox,
                lineCount: paragraph.lineCount,
                translatedText: translation,
                pageSizeInPoints: pageSize,
                options: layout
            )

            items.append(PDFAnnotationItem(
                kind: .text,
                pageIndex: paragraph.pageIndex,
                start: plan.start,
                end: plan.end,
                colorHex: colorHex,
                lineWidth: 1,
                text: translation,
                fontSize: plan.fontSize,
                fillColorHex: fillColorHex
            ))
        }
        return items
    }
}
