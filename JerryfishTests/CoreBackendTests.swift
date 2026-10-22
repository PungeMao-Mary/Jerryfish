import CoreGraphics
import XCTest
@testable import Jerryfish

// ============================================================
// TextBlockGrouper 单元测试：散行 → 段落的版面聚类
// ============================================================

final class TextBlockGrouperTests: XCTestCase {

    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.5, h: CGFloat = 0.02) -> TextBlockGrouper.Line {
        TextBlockGrouper.Line(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h))
    }

    func testSingleSpacedParagraphIsOneBlock() {
        let lines = [
            line("Deep learning models have", x: 0.1, y: 0.10),
            line("achieved strong results on", x: 0.1, y: 0.125),
            line("many public benchmarks.", x: 0.1, y: 0.15),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].lineCount, 3)
    }

    func testParagraphGapSplitsBlocks() {
        let lines = [
            line("First paragraph line one", x: 0.1, y: 0.10),
            line("first paragraph line two", x: 0.1, y: 0.125),
            // 0.05 的大间距 → 新段落
            line("Second paragraph starts", x: 0.1, y: 0.20),
            line("and continues here.", x: 0.1, y: 0.225),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].lineCount, 2)
        XCTAssertEqual(blocks[1].lineCount, 2)
    }

    func testDoubleSpacedParagraphIsOneBlock() {
        // 双倍行距：行距大，但段间距更大；自适应阈值必须仍然正确
        let lines = [
            line("A double spaced thesis line", x: 0.1, y: 0.10, h: 0.024),
            line("followed by another line", x: 0.1, y: 0.148, h: 0.024),
            line("and a third one here", x: 0.1, y: 0.196, h: 0.024),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        XCTAssertEqual(blocks.count, 1, "双倍行距不应被误判为段落")
    }

    func testTwoColumnLayoutIsNotMerged() {
        let lines = [
            line("Left column line one", x: 0.06, y: 0.10, w: 0.42),
            line("Right column line one", x: 0.52, y: 0.10, w: 0.42),
            line("Left column line two", x: 0.06, y: 0.125, w: 0.42),
            line("Right column line two", x: 0.52, y: 0.125, w: 0.42),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        XCTAssertEqual(blocks.count, 4, "左右栏不得被聚成一段")
        XCTAssertEqual(Set(blocks.map { $0.text }),
                       ["Left column line one", "Right column line one",
                        "Left column line two", "Right column line two"])
    }

    func testReadingOrderIsTopToBottom() {
        let lines = [
            line("third", x: 0.1, y: 0.15),
            line("first", x: 0.1, y: 0.10),
            line("second", x: 0.1, y: 0.125),
        ]
        let blocks = TextBlockGrouper.group(lines: lines, options: .init(lineJoiner: .space))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "first second third")
    }

    func testUnionBoundingBox() {
        let lines = [
            line("a", x: 0.10, y: 0.10, w: 0.30, h: 0.02),
            line("b", x: 0.12, y: 0.13, w: 0.40, h: 0.02),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].boundingBox.minX, 0.10, accuracy: 0.0001)
        XCTAssertEqual(blocks[0].boundingBox.minY, 0.10, accuracy: 0.0001)
        XCTAssertEqual(blocks[0].boundingBox.maxX, 0.52, accuracy: 0.0001)
        XCTAssertEqual(blocks[0].boundingBox.maxY, 0.15, accuracy: 0.0001)
    }

    func testEmptyInputProducesNoBlocks() {
        XCTAssertTrue(TextBlockGrouper.group(lines: []).isEmpty)
        XCTAssertTrue(TextBlockGrouper.group(lines: [line("   ", x: 0, y: 0)]).isEmpty)
    }

    func testAverageConfidenceIsAveraged() {
        let lines = [
            TextBlockGrouper.Line(text: "a", boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.02), confidence: 0.4),
            TextBlockGrouper.Line(text: "b", boundingBox: CGRect(x: 0, y: 0.02, width: 0.1, height: 0.02), confidence: 0.6),
        ]
        let blocks = TextBlockGrouper.group(lines: lines)
        XCTAssertEqual(blocks[0].averageConfidence, 0.5, accuracy: 0.0001)
    }

    func testMedianIsRobustToOutliers() {
        XCTAssertEqual(TextBlockGrouper.median([0.02, 0.021, 0.02, 0.9]), 0.0205, accuracy: 0.0001)
        XCTAssertEqual(TextBlockGrouper.median([]), 0)
        XCTAssertEqual(TextBlockGrouper.median([5]), 5)
    }
}

// ============================================================
// PDFTranslationOverlayLayout 单元测试：译文批注框几何求解
// ============================================================

final class PDFTranslationOverlayLayoutTests: XCTestCase {

    private let a4 = CGSize(width: 595, height: 842)

    func testShortTranslationKeepsSourceTopEdge() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.02)
        let plan = PDFTranslationOverlayLayout.plan(
            box: box, lineCount: 1, translatedText: "简短译文", pageSizeInPoints: a4
        )
        XCTAssertEqual(plan.start.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(plan.start.y, 0.2, accuracy: 0.0001)
        XCTAssertGreaterThan(plan.end.y, plan.start.y)
        XCTAssertLessThanOrEqual(plan.end.y, 1.0)
        XCTAssertGreaterThan(plan.fontSize, 0)
    }

    func testLongTranslationExpandsDownwardsWithinPage() {
        let box = CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.02)
        let plan = PDFTranslationOverlayLayout.plan(
            box: box, lineCount: 1,
            translatedText: String(repeating: "这是一段很长的中文译文用于测试换行行为。", count: 8),
            pageSizeInPoints: a4
        )
        XCTAssertGreaterThanOrEqual(plan.start.y, 0)
        XCTAssertLessThanOrEqual(plan.end.y, 1.0)
        XCTAssertGreaterThan(plan.end.y, plan.start.y)
        XCTAssertLessThanOrEqual(plan.end.y - plan.start.y, 0.9 + 0.0001)
    }

    func testNarrowColumnIsWidenedToMinimum() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.03, height: 0.02)
        let plan = PDFTranslationOverlayLayout.plan(
            box: box, lineCount: 1, translatedText: "窄栏译文", pageSizeInPoints: a4
        )
        let width = plan.end.x - plan.start.x
        XCTAssertGreaterThanOrEqual(width, PDFTranslationOverlayLayout.Options.default.minimumWidthFraction - 0.0001)
    }

    func testWidenedBoxIsClampedToPageWidth() {
        let box = CGRect(x: 0.95, y: 0.2, width: 0.5, height: 0.02)
        let plan = PDFTranslationOverlayLayout.plan(
            box: box, lineCount: 2, translatedText: "靠右边缘的译文", pageSizeInPoints: a4
        )
        XCTAssertLessThanOrEqual(plan.end.x, 1.0 + 0.0001)
        XCTAssertGreaterThanOrEqual(plan.start.x, 0)
    }

    func testFontSizeShrinksForVeryLongParagraph() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.1)
        let short = PDFTranslationOverlayLayout.plan(
            box: box, lineCount: 5, translatedText: "短句", pageSizeInPoints: a4
        )
        let long = PDFTranslationOverlayLayout.plan(
            box: box, lineCount: 5,
            translatedText: String(repeating: "很长的译文内容", count: 60),
            pageSizeInPoints: a4
        )
        XCTAssertLessThan(long.fontSize, short.fontSize)
        XCTAssertGreaterThan(long.estimatedLines, 1)
    }

    /// 回归：译文较短时批注框**不得**缩进原文包围盒内部，否则原文会露出来
    func testAnnotationNeverShrinksInsideSourceBox() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.15)   // 一个「多行」大块
        let plan = PDFTranslationOverlayLayout.plan(
            box: box, lineCount: 5, translatedText: "短译文。", pageSizeInPoints: a4
        )
        XCTAssertGreaterThanOrEqual(plan.start.x, 0)
        XCTAssertLessThanOrEqual(plan.start.y, box.minY + 0.0001, "起点不应低于原文顶部")
        XCTAssertGreaterThanOrEqual(plan.end.x + 0.0001, box.maxX, "宽度必须覆盖原文")
        XCTAssertGreaterThanOrEqual(plan.end.y + 0.0001, box.maxY,
                                    "高度必须覆盖原文（否则原文会露出来）")
    }

    func testEmptyTranslationStillProducesValidGeometry() {
        let plan = PDFTranslationOverlayLayout.plan(
            box: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.02),
            lineCount: 1, translatedText: "", pageSizeInPoints: a4
        )
        XCTAssertLessThanOrEqual(plan.end.y, 1.0)
        XCTAssertGreaterThan(plan.end.y, plan.start.y)
    }
}

// ============================================================
// Vision OCR 坐标归一化测试（不依赖真实图像）
// ============================================================

final class OCRGeometryTests: XCTestCase {

    func testVisionBottomLeftRectIsFlippedToTopLeft() {
        // Vision：原点左下。y=0.7 高 0.1 → 顶边距顶部 0.2
        let visionRect = CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1)
        let converted = VisionOCRService.topLeftNormalizedRect(from: visionRect)
        XCTAssertEqual(converted.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(converted.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(converted.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(converted.height, 0.1, accuracy: 0.0001)
    }

    func testOutOfBoundsRectIsClamped() {
        let converted = VisionOCRService.topLeftNormalizedRect(
            from: CGRect(x: -0.2, y: -0.2, width: 1.6, height: 1.6)
        )
        XCTAssertGreaterThanOrEqual(converted.minX, 0)
        XCTAssertGreaterThanOrEqual(converted.minY, 0)
        XCTAssertLessThanOrEqual(converted.maxX, 1.0001)
        XCTAssertLessThanOrEqual(converted.maxY, 1.0001)
    }

    func testReadingOrderSortsTopToBottomLeftToRight() {
        let lines = [
            OCRLine(text: "right", confidence: 1, boundingBox: CGRect(x: 0.5, y: 0.10, width: 0.3, height: 0.02)),
            OCRLine(text: "left", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.101, width: 0.3, height: 0.02)),
            OCRLine(text: "bottom", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.30, width: 0.3, height: 0.02)),
        ]
        let sorted = VisionOCRService.sortReadingOrder(lines)
        XCTAssertEqual(sorted.map(\.text), ["left", "right", "bottom"])
    }
}

// ============================================================
// 屏幕坐标系换算测试
// ============================================================

final class ScreenGeometryTests: XCTestCase {

    func testCocoaToGlobalTopLeftRoundTrip() throws {
        let height = ScreenGeometry.primaryDisplayHeight
        try XCTSkipIf(height <= 0, "无可用显示器，跳过坐标系测试")
        let cocoa = CGRect(x: 120, y: 300, width: 400, height: 200)
        let global = ScreenGeometry.toGlobalTopLeft(cocoa)
        XCTAssertEqual(global.minX, cocoa.minX, accuracy: 0.001)
        XCTAssertEqual(global.minY, height - cocoa.maxY, accuracy: 0.001)
        let back = ScreenGeometry.toCocoa(global)
        XCTAssertEqual(back.minX, cocoa.minX, accuracy: 0.001)
        XCTAssertEqual(back.minY, cocoa.minY, accuracy: 0.001)
        XCTAssertEqual(back.height, cocoa.height, accuracy: 0.001)
    }

    func testCropUsesDisplayScaleCorrectly() {
        // 构造 2x 的整屏位图，验证裁剪区域按比例映射
        let width = 200
        let height = 400
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ), let image = context.makeImage() else {
            return XCTFail("无法创建测试位图")
        }
        let displayBounds = CGRect(x: 0, y: 0, width: 100, height: 200) // 2x
        let globalRect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let cropped = try? ScreenCaptureService.crop(image, globalRect: globalRect, displayBounds: displayBounds)
        XCTAssertEqual(cropped?.width, 60)
        XCTAssertEqual(cropped?.height, 80)
    }

    func testCropRejectsOutOfBoundsSelection() {
        guard let context = CGContext(
            data: nil, width: 50, height: 50,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ), let image = context.makeImage() else {
            return XCTFail("无法创建测试位图")
        }
        XCTAssertThrowsError(try ScreenCaptureService.crop(
            image,
            globalRect: CGRect(x: 500, y: 500, width: 20, height: 20),
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        ))
    }
}

// ============================================================
// 译文批注映射测试（不依赖 UI）
// ============================================================

@MainActor
final class TranslationAnnotationFactoryTests: XCTestCase {

    func testOnlyNonEmptyTranslationsProduceAnnotations() {
        let paragraphs = [
            PDFTextParagraph(pageIndex: 0, text: "First paragraph.", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.03)),
            PDFTextParagraph(pageIndex: 0, text: "Second paragraph.", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.03)),
            PDFTextParagraph(pageIndex: 1, text: "Third paragraph.", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.03)),
        ]
        let items = PDFTranslationAnnotationFactory.makeAnnotations(
            paragraphs: paragraphs,
            translations: ["第一段。", "", "第三段。"],
            pageSizes: [CGSize(width: 595, height: 842), CGSize(width: 595, height: 842)]
        )
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.pageIndex), [0, 1])
        XCTAssertEqual(items.map(\.text), ["第一段。", "第三段。"])
        XCTAssertTrue(items.allSatisfy { $0.kind == .text })
        XCTAssertEqual(items.first?.colorHex, PDFTranslationAnnotationFactory.defaultColorHex)
    }

    func testAnnotationCoordinatesAreNormalisedAndOnPage() {
        let paragraph = PDFTextParagraph(
            pageIndex: 0,
            text: "A sentence with enough characters.",
            boundingBox: CGRect(x: 0.12, y: 0.4, width: 0.6, height: 0.025)
        )
        let items = PDFTranslationAnnotationFactory.makeAnnotations(
            paragraphs: [paragraph],
            translations: ["一个足够长的中文句子，用来验证批注框不会超出页面范围。"],
            pageSizes: [CGSize(width: 595, height: 842)]
        )
        guard let item = items.first else { return XCTFail("应生成一条批注") }
        XCTAssertGreaterThanOrEqual(item.start.x, 0)
        XCTAssertGreaterThanOrEqual(item.start.y, 0)
        XCTAssertLessThanOrEqual(item.end.x, 1.0 + 0.0001)
        XCTAssertLessThanOrEqual(item.end.y, 1.0 + 0.0001)
        XCTAssertLessThanOrEqual(item.start.y, item.end.y)
    }

    func testMissingPageSizeFallsBackToA4() {
        let paragraph = PDFTextParagraph(
            pageIndex: 7,
            text: "Page seven paragraph.",
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.03)
        )
        let items = PDFTranslationAnnotationFactory.makeAnnotations(
            paragraphs: [paragraph],
            translations: ["第七页段落。"],
            pageSizes: []
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertGreaterThan(items[0].fontSize, 0)
    }
}
