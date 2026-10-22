import CoreGraphics
import Foundation

// ============================================================
// 行 → 段落（文本块）聚合器
//
// OCR（Vision 输出逐行观测）与 PDF 文本层提取都会得到「一堆散行」。
// 直接把散行送去翻译会得到碎片化、语义断裂的结果，因此这里做版面聚类：
//   - 垂直方向按「自适应行距阈值」判断是否同段
//   - 水平方向必须同列（避免双栏论文左右栏被串成一句）
//
// 坐标约定：归一化、原点左上、0...1（与 PDFAnnotationItem 完全一致）。
// ============================================================

nonisolated public enum TextBlockGrouper {

    /// 输入行。
    public struct Line: Sendable, Equatable {
        public var text: String
        /// 归一化包围盒（原点左上）
        public var boundingBox: CGRect
        public var confidence: Float

        public init(text: String, boundingBox: CGRect, confidence: Float = 1) {
            self.text = text
            self.boundingBox = boundingBox
            self.confidence = confidence
        }
    }

    /// 聚合后的文本块。
    public struct Block: Sendable, Equatable {
        public var text: String
        /// 块内所有行的并集包围盒（归一化，原点左上）
        public var boundingBox: CGRect
        public var lineCount: Int
        public var averageConfidence: Float
    }

    /// 文本块内部的换行符策略。
    public enum LineJoiner: Sendable {
        /// 用空格连接（适合宽高固定的文本框 / 单栏段落）
        case space
        /// 用换行连接（保留视觉结构，交给 TextSanitizer 处理连字符）
        case newline
    }

    /// 聚合参数。
    public struct Options: Sendable {
        /// 同列判定：两行水平投影重叠比例下限
        public var columnOverlapRatio: CGFloat
        /// 行距基准下限（相对中位行高）
        public var minimumGapRatio: CGFloat
        /// 行距基准之外的额外容差（相对中位行高）
        public var gapToleranceRatio: CGFloat
        public var lineJoiner: LineJoiner

        public init(
            columnOverlapRatio: CGFloat = 0.55,
            minimumGapRatio: CGFloat = 0.34,
            gapToleranceRatio: CGFloat = 0.26,
            lineJoiner: LineJoiner = .newline
        ) {
            self.columnOverlapRatio = columnOverlapRatio
            self.minimumGapRatio = minimumGapRatio
            self.gapToleranceRatio = gapToleranceRatio
            self.lineJoiner = lineJoiner
        }

        public static let `default` = Options()
    }

    // MARK: - 主入口

    public static func group(lines: [Line], options: Options = .default) -> [Block] {
        let input = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !input.isEmpty else { return [] }
        guard input.count > 1 else {
            return [makeBlock(from: [input[0]], options: options)]
        }

        let sorted = input.sorted { lhs, rhs in
            if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.004 {
                return lhs.boundingBox.minY < rhs.boundingBox.minY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        let medianHeight = median(sorted.map { $0.boundingBox.height })
        let breakThreshold = adaptiveBreakThreshold(for: sorted, medianHeight: medianHeight, options: options)

        var blocks: [[Line]] = []
        var current: [Line] = []

        for line in sorted {
            guard let last = current.last else {
                current = [line]
                continue
            }
            if continuesParagraph(current: current, last: last, next: line,
                                  breakThreshold: breakThreshold, options: options) {
                current.append(line)
            } else {
                blocks.append(current)
                current = [line]
            }
        }
        if !current.isEmpty { blocks.append(current) }

        return blocks.map { makeBlock(from: $0, options: options) }
    }

    // MARK: - 段落判定

    private static func continuesParagraph(
        current: [Line],
        last: Line,
        next: Line,
        breakThreshold: CGFloat,
        options: Options
    ) -> Bool {
        // 1. 必须同列：与「当前段落已占用的水平区间」有足够重叠
        let union = current.reduce(last.boundingBox) { $0.union($1.boundingBox) }
        guard horizontalOverlapRatio(union, next.boundingBox) >= options.columnOverlapRatio else {
            return false
        }
        // 2. 垂直间距必须足够小
        let gap = next.boundingBox.minY - union.maxY
        // 轻微负间距（行高框有重叠 / 上标）视为连续
        if gap <= 0 { return true }
        return gap <= breakThreshold
    }

    private static func horizontalOverlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let lower = max(a.minX, b.minX)
        let upper = min(a.maxX, b.maxX)
        let overlap = upper - lower
        guard overlap > 0 else { return 0 }
        let reference = min(a.width, b.width)
        guard reference > 0.0001 else { return 0 }
        return overlap / reference
    }

    /// 自适应行距阈值：以实际行距中位数为基准，段间距通常明显大于行内行距。
    /// 单倍行距 \ 双倍行距 \ 单栏 \ 双栏 均可自适应。
    private static func adaptiveBreakThreshold(
        for sorted: [Line],
        medianHeight: CGFloat,
        options: Options
    ) -> CGFloat {
        var gaps: [CGFloat] = []
        for index in 1..<sorted.count {
            let previous = sorted[index - 1].boundingBox
            let box = sorted[index].boundingBox
            let gap = box.minY - previous.maxY
            if gap > -0.02, gap < 1.2 { gaps.append(gap) }
        }
        let base = gaps.isEmpty ? medianHeight * 0.5 : median(gaps)
        return max(medianHeight * options.minimumGapRatio,
                   base + medianHeight * options.gapToleranceRatio)
    }

    // MARK: - 输出

    private static func makeBlock(from lines: [Line], options: Options) -> Block {
        let box = lines.dropFirst().reduce(lines[0].boundingBox) { $0.union($1.boundingBox) }
        let separator: String
        switch options.lineJoiner {
        case .space: separator = " "
        case .newline: separator = "\n"
        }
        let text = lines.map(\.text).joined(separator: separator)
        let confidence = lines.map(\.confidence).reduce(0, +) / Float(lines.count)
        return Block(text: text, boundingBox: box, lineCount: lines.count, averageConfidence: confidence)
    }

    // MARK: - 统计工具

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
