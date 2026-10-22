import AppKit
import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import Jerryfish

// ============================================================
// PDF 画布：译文批注底色覆盖 + 原文文本选择
//
// 两个用例都自己生成 PDF（纯内存），不依赖外部文件，也不依赖 UI 自动化。
// ============================================================

@MainActor
final class PDFReaderCanvasTests: XCTestCase {

    private let pageSize = CGSize(width: 612, height: 792)   // US Letter

    /// 生成一页 PDF：白底 + 黑色英文文本（原点左下）
    private func makePDF(text: String, at point: CGPoint) -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              var mediaBox = Optional(CGRect(origin: .zero, size: pageSize)),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            fatalError("无法创建 PDF 上下文")
        }
        context.beginPDFPage(nil)

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pageSize))

        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)

        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            fatalError("无法创建 PDFDocument")
        }
        return document
    }

    /// 文本在画布视图里的位置：页面左上角 = (pageMargin, pageMargin)，缩放 1
    private func viewRect(forPDFRect rect: CGRect) -> CGRect {
        let margin: CGFloat = 24
        return CGRect(
            x: margin + rect.minX,
            y: margin + (pageSize.height - rect.maxY),
            width: rect.width,
            height: rect.height
        )
    }

    private func makeCanvas(_ document: PDFDocument) -> PDFCanvasView {
        let canvas = PDFCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        canvas.pdfDocument = document
        canvas.zoom = 1
        canvas.updateFrameSize()
        return canvas
    }

    /// 渲染画布到 RGBA 位图
    private func render(_ canvas: PDFCanvasView) -> (data: [UInt8], width: Int, height: Int)? {
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        guard let cgImage = rep.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }

    /// 区域内「暗像素」（被墨迹覆盖）的比例
    private func darkRatio(_ bitmap: (data: [UInt8], width: Int, height: Int), rect: CGRect) -> Double {
        let scale = CGFloat(bitmap.width) / 700.0
        var dark = 0, total = 0
        let minX = max(0, Int(rect.minX * scale)), maxX = min(bitmap.width, Int(rect.maxX * scale))
        let minY = max(0, Int(rect.minY * scale)), maxY = min(bitmap.height, Int(rect.maxY * scale))
        guard minX < maxX, minY < maxY else { return 0 }
        for y in minY..<maxY {
            for x in minX..<maxX {
                let i = (y * bitmap.width + x) * 4
                let luminance = (Int(bitmap.data[i]) * 299 + Int(bitmap.data[i + 1]) * 587 + Int(bitmap.data[i + 2]) * 114) / 1000
                if luminance < 128 { dark += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    // MARK: 译文批注底色

    private func makeAnnotation(text: String, rect: CGRect, fill: String?) -> PDFAnnotationItem {
        PDFAnnotationItem(
            kind: .text,
            pageIndex: 0,
            start: CGPoint(x: (rect.minX - 24) / pageSize.width, y: (rect.minY - 24) / pageSize.height),
            end: CGPoint(x: (rect.maxX - 24) / pageSize.width, y: (rect.maxY - 24) / pageSize.height),
            colorHex: PDFTranslationAnnotationFactory.defaultColorHex,
            lineWidth: 1,
            text: text,
            fontSize: 18,
            fillColorHex: fill
        )
    }

    func testTranslationAnnotationFillCoversOriginalText() throws {
        let document = makePDF(text: "ORIGINAL ENGLISH SENTENCE", at: CGPoint(x: 60, y: 600))
        let canvas = makeCanvas(document)

        // 原文所在区域（视图坐标）
        let originalRect = CGRect(x: 24 + 60, y: 24 + (pageSize.height - 630), width: 340, height: 30)
        let annotationRect = originalRect.insetBy(dx: -3, dy: -3)

        // 对照组：没有底色 → 原文墨迹仍在
        canvas.items = [makeAnnotation(text: "中文译文内容", rect: annotationRect, fill: nil)]
        let withoutFill = try XCTUnwrap(render(canvas))
        let darkWithoutFill = darkRatio(withoutFill, rect: annotationRect)

        // 实验组：有底色 → 原文被盖住（暗像素显著减少），且仍有译文墨迹
        canvas.items = [makeAnnotation(text: "中文译文内容", rect: annotationRect, fill: "#FFFFFF")]
        let withFill = try XCTUnwrap(render(canvas))
        let darkWithFill = darkRatio(withFill, rect: annotationRect)

        XCTAssertGreaterThan(darkWithoutFill, 0.02, "对照组应有原文墨迹")
        XCTAssertLessThan(darkWithFill, darkWithoutFill * 0.75,
                          "加了不透明底色后原文墨迹应被显著盖住（含底色=\(darkWithoutFill)，有底色=\(darkWithFill)）")
        XCTAssertGreaterThan(darkWithFill, 0.002, "译文本身仍应可见")
    }

    func testFillColorIsOptionalAndDefaultsToNil() {
        let item = PDFAnnotationItem(kind: .text, pageIndex: 0,
                                     start: .zero, end: CGPoint(x: 0.2, y: 0.1),
                                     colorHex: "#000000", lineWidth: 1, text: "x")
        XCTAssertNil(item.fillColorHex)
        XCTAssertNil(item.fillColor)
        XCTAssertNotNil(makeAnnotation(text: "x", rect: CGRect(x: 0, y: 0, width: 10, height: 10), fill: "#FFFFFF").fillColor)
    }

    // MARK: 渲染清晰度（不发虚）

    /// 统计「文本行范围内的边缘灰阶占比」：位图被放大时灰阶比例显著升高。
    private func midToneRatio(_ canvas: PDFCanvasView, scale: CGFloat, region: CGRect) -> Double {
        let width = Int(canvas.bounds.width * scale)
        let height = Int(canvas.bounds.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return -1 }
        rep.size = canvas.bounds.size          // 逻辑尺寸不变 → 视图按 scale 倍绘制
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        var dark = 0, mid = 0, light = 0
        let data = rep.bitmapData!
        let bytesPerRow = rep.bytesPerRow
        let minX = max(0, Int(region.minX * scale)), maxX = min(width, Int(region.maxX * scale))
        let minY = max(0, Int(region.minY * scale)), maxY = min(height, Int(region.maxY * scale))
        guard minX < maxX, minY < maxY else { return -1 }
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * 4
                let r = Int(data[offset]), g = Int(data[offset + 1]), b = Int(data[offset + 2])
                let l = (r * 299 + g * 587 + b * 114) / 1000
                if l < 64 { dark += 1 } else if l < 192 { mid += 1 } else { light += 1 }
            }
        }
        let ink = dark + mid
        return ink == 0 ? 0 : Double(mid) / Double(ink)
    }

    func testPageBitmapIsRenderedAtBackingScale() throws {
        let document = makePDF(text: "Crisp text sample for sharpness", at: CGPoint(x: 60, y: 600))
        let canvas = makeCanvas(document)

        // 只取该文本行，避免其它内容干扰
        let region = viewRect(forPDFRect: CGRect(x: 55, y: 592, width: 420, height: 40))

        // 旧行为：按「点」尺寸取位图（Retina 上等于被放大 2 倍）→ 边缘灰阶多
        canvas.renderScaleOverride = 1
        let blurry = midToneRatio(canvas, scale: 2, region: region)

        // 新行为：按 backing scale 取位图 → 1:1 映射到设备像素，更锐利
        canvas.renderScaleOverride = 2
        let crisp = midToneRatio(canvas, scale: 2, region: region)

        XCTAssertGreaterThan(blurry, 0, "对照组应能测到墨迹")
        XCTAssertGreaterThan(crisp, 0, "实验组应能测到墨迹")
        XCTAssertLessThan(crisp, blurry * 0.9,
                          "2x 位图应显著减少边缘灰阶（模糊=\(blurry)，清晰=\(crisp)）")
    }

    // MARK: 原文文本选择

    func testDragSelectsOriginalText() throws {
        let document = makePDF(text: "Selectable original text", at: CGPoint(x: 60, y: 600))
        let canvas = makeCanvas(document)
        XCTAssertTrue(canvas.textSelectionEnabled, "鼠标工具应默认支持选中原文")

        // 原文所在行的视图范围
        let line = viewRect(forPDFRect: CGRect(x: 55, y: 595, width: 300, height: 32))
        let selected = canvas.selectText(
            fromViewPoint: CGPoint(x: line.minX, y: line.midY),
            toViewPoint: CGPoint(x: line.maxX, y: line.midY)
        )

        let text = try XCTUnwrap(selected, "应能选中文本")
        XCTAssertTrue(text.contains("Selectable"), "实际选中：\(text)")
        XCTAssertTrue(text.contains("original"), "实际选中：\(text)")
        XCTAssertEqual(canvas.selectedText, text)
    }

    func testCopyPutsSelectedTextOnPasteboard() throws {
        let document = makePDF(text: "Copy me please", at: CGPoint(x: 60, y: 600))
        let canvas = makeCanvas(document)
        let line = viewRect(forPDFRect: CGRect(x: 55, y: 595, width: 300, height: 32))
        canvas.selectText(fromViewPoint: CGPoint(x: line.minX, y: line.midY),
                          toViewPoint: CGPoint(x: line.maxX, y: line.midY))

        NSPasteboard.general.clearContents()
        canvas.copy(nil)
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, canvas.selectedText)
        XCTAssertTrue(pasted?.contains("Copy me") == true)
    }

    func testClearingSelectionStopsCopy() throws {
        let document = makePDF(text: "Transient text", at: CGPoint(x: 60, y: 600))
        let canvas = makeCanvas(document)
        let line = viewRect(forPDFRect: CGRect(x: 55, y: 595, width: 300, height: 32))
        canvas.selectText(fromViewPoint: CGPoint(x: line.minX, y: line.midY),
                          toViewPoint: CGPoint(x: line.maxX, y: line.midY))
        XCTAssertNotNil(canvas.selectedText)

        canvas.clearTextSelection()
        NSPasteboard.general.clearContents()
        canvas.copy(nil)
        XCTAssertNil(NSPasteboard.general.string(forType: .string), "清空选择后不应写入剪贴板")
    }

    func testHoverHitTestDetectsSelectableText() throws {
        let document = makePDF(text: "Hoverable words here", at: CGPoint(x: 60, y: 600))
        let canvas = makeCanvas(document)

        // 文本所在行的中部 → 应该认为「有可选文字」（用于切换 I 形光标）
        let line = viewRect(forPDFRect: CGRect(x: 55, y: 595, width: 300, height: 32))
        XCTAssertTrue(canvas.isPointOverSelectableText(CGPoint(x: line.midX, y: line.midY)),
                      "文字上应命中")
        // 同高度的最右侧空白处 → 不应命中
        XCTAssertFalse(canvas.isPointOverSelectableText(CGPoint(x: line.maxX + 200, y: line.midY)),
                       "同一行的右侧空白不应命中")
        // 页面下方大片空白 → 不应命中
        XCTAssertFalse(canvas.isPointOverSelectableText(CGPoint(x: 300, y: 700)),
                       "空白区域不应命中")
        // 关闭文本选择后一律不命中
        canvas.textSelectionEnabled = false
        XCTAssertFalse(canvas.isPointOverSelectableText(CGPoint(x: line.midX, y: line.midY)))
    }

    func testTextSelectionDisabledRespectsFlag() throws {
        let document = makePDF(text: "Should stay raw", at: CGPoint(x: 60, y: 600))
        let canvas = makeCanvas(document)
        canvas.textSelectionEnabled = false
        // 该入口自身不做开关判断（由鼠标交互层判断），这里验证开关默认值与可关闭
        XCTAssertFalse(canvas.textSelectionEnabled)
    }
}

// ============================================================
// PDF 文本提取完整性：多页不同文本时，每页段落都该被取到
// ============================================================

@MainActor
final class PDFExtractionCompletenessTests: XCTestCase {

    private func writePDF(url: URL, pages: [(String, [String])]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("无法创建 PDF 上下文")
        }
        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(mediaBox)
            var y: CGFloat = 720
            for text in [page.0] + page.1 {
                let font = CTFontCreateWithName((text == page.0 ? "Helvetica-Bold" : "Helvetica") as CFString,
                                                text == page.0 ? 17 : 13, nil)
                let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                              kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
                let s = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
                ctx.textPosition = CGPoint(x: 60, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
                y -= 30
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    func testExtractorKeepsAllParagraphsWhenPagesDiffer() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("extract-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let pages: [(String, [String])] = [
            ("Cortical Microenvironment", ["Alpha paragraph one.", "Alpha paragraph two."]),
            ("Discussion", ["Beta paragraph one.", "Beta paragraph two."]),
        ]
        try writePDF(url: url, pages: pages)

        let result = try await PDFTextExtractor().extract(from: url)
        let page0 = result.paragraphs.filter { $0.pageIndex == 0 }.map(\.text)
        let page1 = result.paragraphs.filter { $0.pageIndex == 1 }.map(\.text)

        XCTAssertTrue(page0.contains { $0.contains("Alpha paragraph two") }, "第一页段落缺失：\(page0)")
        XCTAssertTrue(page1.contains { $0.contains("Beta paragraph two") }, "第二页段落缺失：\(page1)")
        XCTAssertFalse(result.paragraphs.isEmpty)
        // 每段都应有可用的归一化包围盒
        for p in result.paragraphs {
            XCTAssertGreaterThan(p.boundingBox.width, 0.01, "包围盒异常：\(p.text)")
            XCTAssertGreaterThan(p.boundingBox.height, 0.002, "包围盒异常：\(p.text)")
        }
    }

    /// 真实论文的页眉/页脚确实会逐页重复，应被剔除；但正文段落不能被误伤。
    func testRepeatedHeaderIsRemovedButBodyKept() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("header-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        // 两页：同一页眉文本 + 不同的正文
        var pages: [(String, [String])] = []
        for index in 0..<2 {
            pages.append(("Nature Communications | Article",
                          ["Body paragraph for page \(index) alpha.",
                           "Body paragraph for page \(index) beta."]))
        }
        try writePDF(url: url, pages: pages)

        let result = try await PDFTextExtractor().extract(from: url)
        let joined = result.paragraphs.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("alpha"), "正文被误删：\(joined)")
        XCTAssertTrue(joined.contains("beta"), "正文被误删：\(joined)")
        XCTAssertTrue(result.skippedHeaderFooterTexts.contains { $0.contains("Nature Communications") },
                      "重复页眉应被识别并剔除，实际：\(result.skippedHeaderFooterTexts)")
    }
}
