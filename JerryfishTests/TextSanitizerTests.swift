import XCTest
@testable import Jerryfish

// ============================================================
// TextSanitizer 单元测试
//
// 覆盖目标（对应 Phase 1 交付要求）：
//   - 跨行截断单词（soft hyphen）还原
//   - 复合词连字符保留（不能误并成非词）
//   - 段落结构保留（空行 → \n\n），段内硬换行 → 空格
//   - 连字 / 软连字符 / NBSP 等排版噪声
//   - 标点空格清理
//   - 幂等性（清洗两次结果一致）
// ============================================================

final class TextSanitizerTests: XCTestCase {

    // MARK: - 跨行连字符

    func testJoinsSoftHyphenatedLineBreak() {
        let input = "The results were experi-\n mental in nature."
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input),
                       "The results were experimental in nature.")
    }

    func testJoinsSoftHyphenationWithTrailingSpaces() {
        let input = "conclu-   \n   sion"
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input), "conclusion")
    }

    func testMultipleSoftHyphenationsInOneParagraph() {
        let input = """
        Regres-\nsion anal-\nysis showed a signi-\nficant effect.
        """
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input),
                       "Regression analysis showed a significant effect.")
    }

    func testPreservesCompoundHyphenWhenSecondPartIsCapitalised() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("non-\nNewtonian fluid"),
                       "non-Newtonian fluid")
    }

    func testPreservesHyphenForAcronymPrefix() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("DNA-\nbinding domain"),
                       "DNA-binding domain")
    }

    func testPreservesKnownCompoundPrefix() {
        // well- 是学术写作中习惯保留连字符的前缀
        XCTAssertEqual(TextSanitizer.cleanAcademicText("a well-\nknown result"),
                       "a well-known result")
    }

    func testPreservesKnownCompoundSuffix() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("a dose-\ndependent response"),
                       "a dose-dependent response")
    }

    func testDoesNotJoinAcrossParagraphBoundary() {
        let input = "The prefix was multi-\n\nlevel analysis."
        let output = TextSanitizer.cleanAcademicText(input)
        XCTAssertTrue(output.contains("\n\n"), "段落边界必须保留：\(output)")
        XCTAssertFalse(output.contains("multilevel"), "不得跨段落合并：\(output)")
    }

    func testNonBreakingHyphenIsNotMerged() {
        // U+2011 NON-BREAKING HYPHEN 表示作者显式要求的不可断连字符
        XCTAssertEqual(TextSanitizer.cleanAcademicText("a well\u{2011}\nknown fact"),
                       "a well\u{2011} known fact")
    }

    func testOptionalWithinLineHyphenJoinIsOffByDefault() {
        let input = "experi- mental"
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input), "experi- mental")
    }

    func testOptionalWithinLineHyphenJoinWhenEnabled() {
        let input = "experi- mental"
        let output = TextSanitizer.cleanAcademicText(
            input,
            options: TextSanitizer.Options(joinsHyphenatedLineBreaksWithinLine: true)
        )
        XCTAssertEqual(output, "experimental")
    }

    // MARK: - 段落与换行

    func testHardWrappedParagraphBecomesSingleLine() {
        let input = """
        Deep learning models have
        achieved strong performance
        on many benchmarks.
        """
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input),
                       "Deep learning models have achieved strong performance on many benchmarks.")
    }

    func testParagraphBreakIsPreserved() {
        let input = "First paragraph.\n\nSecond paragraph."
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input), "First paragraph.\n\nSecond paragraph.")
    }

    func testWhitespaceOnlyLineActsAsParagraphBreak() {
        let input = "First.\n   \t \nSecond."
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input), "First.\n\nSecond.")
    }

    func testMultipleBlankLinesCollapse() {
        let input = "A.\n\n\n\n\nB."
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input), "A.\n\nB.")
    }

    func testCRLFLineEndings() {
        let input = "line one\r\nline two\r\n\r\nparagraph two"
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input), "line one line two\n\nparagraph two")
    }

    func testCarriageReturnOnlyLineEndings() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("a\rb"), "a b")
    }

    func testUnicodeLineAndParagraphSeparators() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("a\u{2028}b"), "a b")
        XCTAssertEqual(TextSanitizer.cleanAcademicText("a\u{2029}b"), "a\n\nb")
    }

    // MARK: - 排版噪声

    func testLigatureNormalisation() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("The e\u{FB03}cient \u{FB01}gure"),
                       "The efficient figure")
        XCTAssertEqual(TextSanitizer.cleanAcademicText("di\u{FB00}erent pro\u{FB01}le"),
                       "different profile")
    }

    func testSoftHyphenCharacterIsRemoved() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("e\u{00AD}xample"), "example")
    }

    func testNonBreakingSpaceBecomesSpace() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("100\u{00A0}mL"), "100 mL")
    }

    func testThinAndEnSpacesBecomeSpace() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("a\u{2009}b\u{2002}c\u{3000}d"), "a b c d")
    }

    func testRepeatedSpacesCollapse() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("too    many     spaces"), "too many spaces")
    }

    func testTabsAndFormFeedsBecomeSpaces() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("a\tb\u{000C}c"), "a b c")
    }

    // MARK: - 标点

    func testRemovesSpaceBeforePunctuation() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("see Fig. 2 ."),
                       "see Fig. 2.")
        XCTAssertEqual(TextSanitizer.cleanAcademicText("et al ."),
                       "et al.")
    }

    func testRemovesSpaceInsideParentheses() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("significant ( p < 0.05 )"),
                       "significant (p < 0.05)")
    }

    func testJoinsLineBreakAfterOpeningParen() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("significant (\np < 0.05)"),
                       "significant (p < 0.05)")
    }

    func testJoinsLineBreakAfterEmDash() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("results\u{2014}\nclearly better"),
                       "results\u{2014}clearly better")
    }

    func testCombiningAccentSpaceIsRemoved() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("Beyonc\u{0065} \u{0301}"),
                       "Beyonc\u{0065}\u{0301}")
    }

    // MARK: - 边界

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText(""), "")
        XCTAssertEqual(TextSanitizer.cleanAcademicText("   \n\t \n "), "")
    }

    func testLeadingAndTrailingWhitespaceTrimmed() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("\n\n  hello world  \n\n"), "hello world")
    }

    func testChineseTextPassesThrough() {
        let input = "本文提出了一种新的方法。\n\n实验结果验证了其有效性。"
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input), input)
    }

    func testNumbersAndUnitsArePreserved() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("Section 2.3, p < 0.001, n = 128"),
                       "Section 2.3, p < 0.001, n = 128")
    }

    func testIdempotencyOnComplexInput() {
        let input = [
            "The e\u{FB03}cient implementation of DNA-",
            "binding predic-",
            "tion is well-",
            "known.",
            "",
            "We pro-",
            "pose a dose-",
            "dependent model",
            "with 100\u{00A0}mL samples .",
        ].joined(separator: "\n")
        let once = TextSanitizer.cleanAcademicText(input)
        let twice = TextSanitizer.cleanAcademicText(once)
        XCTAssertEqual(once, twice, "清洗必须幂等")
        XCTAssertTrue(once.contains("DNA-binding prediction is well-known."), once)
        XCTAssertTrue(once.contains("We propose a dose-dependent model"), once)
        XCTAssertTrue(once.contains("100 mL samples."), once)
    }

    // MARK: - 连字符链条

    func testMultiHyphenCompoundSurvivesLineBreak() {
        let input = "a state-of-\nthe-art model"
        XCTAssertEqual(TextSanitizer.cleanAcademicText(input),
                       "a state-of-the-art model")
    }

    func testCommonPrefixesAreJoinedWhenTheyFormRealWords() {
        XCTAssertEqual(TextSanitizer.cleanAcademicText("non-\nlinear dynamics"),
                       "nonlinear dynamics")
        XCTAssertEqual(TextSanitizer.cleanAcademicText("multi-\nmodal learning"),
                       "multimodal learning")
        XCTAssertEqual(TextSanitizer.cleanAcademicText("Un-\nlike prior work"),
                       "Unlike prior work")
    }

    // MARK: - 真实论文摘要片段

    func testRealisticAbstractSnippet() {
        let input = [
            "We present a trans-",
            "former-based architec-",
            "ture for protein struc-",
            "ture prediction. Un-",
            "like previous work,",
            "our model achieves state-of-the-art per-",
            "formance on",
            "CASP14 with an aver-",
            "age GDT-TS of 87.2.",
            "",
            "Keywords: protein folding ; deep learning .",
        ].joined(separator: "\n")
        let output = TextSanitizer.cleanAcademicText(input)

        XCTAssertTrue(output.contains("transformer-based architecture"), output)
        XCTAssertTrue(output.contains("structure prediction"), output)
        XCTAssertTrue(output.contains("Unlike previous work"), output)
        XCTAssertTrue(output.contains("state-of-the-art performance"), output)
        XCTAssertTrue(output.contains("average GDT-TS of 87.2"), output)
        XCTAssertTrue(output.contains("\n\n"), "摘要与关键词之间应为段落：\(output)")
        XCTAssertFalse(output.contains("  "), "不应残留连续空格：\(output)")
        XCTAssertTrue(output.contains("Keywords: protein folding; deep learning."), output)
    }

    // MARK: - 诊断

    func testReportCountsSanitisationEffects() {
        let input = "e\u{FB01}cient\nsoft\u{00AD}ware\n\nsecond"
        let report = TextSanitizer.report(on: input)
        XCTAssertEqual(report.restoredLigatures, 1)
        XCTAssertEqual(report.removedSoftHyphens, 1)
        XCTAssertEqual(report.paragraphCount, 2)
        XCTAssertGreaterThan(report.outputCharacterCount, 0)
    }
}
