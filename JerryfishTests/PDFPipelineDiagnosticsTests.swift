import CoreGraphics
import CoreText
import XCTest
@testable import Jerryfish

// ============================================================
// PDF 全篇翻译流水线：提取 → 分段翻译 的完整性
//
// 覆盖「译文与原文重叠 / 某些段落没被覆盖」这类问题的根因面：
// 每个段落都必须有非空文本，并且每一段都必须拿到非空译文。
// ============================================================

final class PDFPipelineDiagnosticsTests: XCTestCase {

    func testEveryParagraphHasTextAndTranslation() async throws {
        // 用测试自己生成的 PDF，避免依赖外部文件
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFTestPDFWriter.write(to: url, pages: [
            ("Cortical Microenvironment in Immune Organization",
             ["Deep learning models have achieved strong performance on many benchmarks.",
              "We present a transformer based architecture for protein structure prediction.",
              "The results show a dose dependent effect after treatment, which was significant.",
              "Dose dependent effects were observed in the treatment group at all time points."]),
            ("Discussion and Statistical Considerations",
             ["Statistical analysis was performed with a mixed effects model in R version 4.3.",
              "All experiments were repeated three times unless otherwise indicated.",
              "The observed differences remained significant after correction for multiple testing.",
              "These findings suggest a previously unrecognized regulatory mechanism."]),
        ])

        let extraction = try await PDFTextExtractor().extract(from: url)
        for p in extraction.paragraphs {
            print("[extract] page=\(p.pageIndex) lines=\(p.lineCount) box=\(p.boundingBox) text=\(p.text.prefix(60))")
        }
        XCTAssertFalse(extraction.paragraphs.isEmpty)
        XCTAssertTrue(extraction.paragraphs.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                      "存在空文本段落")

        // 「每段都必须拿到非空译文」需要真实翻译引擎，默认跳过（见 LiveEngineTests）
        try XCTSkipUnless(LiveEngineTests.enabled, "需要真实引擎：设置 JERRYFISH_LIVE_ENGINE_TESTS=1 后运行")

        let service = TranslationService()
        await service.refreshAvailability(force: true)
        guard let pair = service.resolvedPair, pair.isInstalled else {
            throw XCTSkip("本机未安装离线包，跳过翻译完整性检查")
        }
        let texts = extraction.paragraphs.map(\.text)
        let translations = try await service.batchTranslate(texts: texts)
        for (index, t) in translations.enumerated() {
            print("[translate] #\(index) -> \(t.prefix(50))")
        }
        XCTAssertEqual(translations.count, texts.count)
        let empties = translations.enumerated().filter { $0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        XCTAssertTrue(empties.isEmpty, "这些段落没拿到译文（会导致原文未被覆盖）：\(empties.map(\.offset))")
        // 译文不应与原文本完全一致（否则等于没翻）
        let untranslated = zip(translations, texts).enumerated().filter { $0.element.0 == $0.element.1 }
        XCTAssertTrue(untranslated.isEmpty, "这些段落译文等于原文：\(untranslated.map(\.offset))")
    }
}

/// 测试用 PDF 生成器
enum PDFTestPDFWriter {
    static func write(to url: URL, pages: [(String, [String])]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("无法创建 PDF 上下文")
        }
        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(mediaBox)
            var y: CGFloat = 720
            for text in [page.0] + page.1 {
                let isTitle = (text == page.0)
                let font = CTFontCreateWithName((isTitle ? "Helvetica-Bold" : "Helvetica") as CFString,
                                                isTitle ? 17 : 13, nil)
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
        try (data as Data).write(to: url)
    }
}
