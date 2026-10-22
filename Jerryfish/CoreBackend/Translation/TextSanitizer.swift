import Foundation

// ============================================================
// 学术文本清洗引擎（纯函数，零 UI 依赖，可跨隔离域调用）
//
// 目标：把「PDF 复制 / OCR」得到的硬折行文本还原成适合机器翻译的段落文本。
//  1. 跨行截断单词还原（soft hyphen）：experi-\n mental → experimental
//  2. 复合词连字符保留：non-\nNewtonian → non-Newtonian（不能误并成 nonNewtonian）
//  3. 段内硬换行 → 空格；空行 → 段落分隔（\n\n）
//  4. 连字（ligature）、软连字符、窄空格等排版噪声归一
//  5. 多余空格与标点前空格清理
//
// 全部函数均为 nonisolated，可在主线程、后台线程或单元测试中直接调用。
// ============================================================

nonisolated public struct TextSanitizer: Sendable {

    // MARK: - 公开入口

    /// 学术文本清洗主入口。
    ///
    /// - Parameter raw: 原始英文（或任意语言）文本。
    /// - Returns: 清洗后的文本；段落之间以单个空行（`\n\n`）分隔，段内无硬换行。
    public static func cleanAcademicText(_ raw: String) -> String {
        cleanAcademicText(raw, options: .default)
    }

    /// 带选项的清洗入口。
    public static func cleanAcademicText(_ raw: String, options: Options) -> String {
        guard !raw.isEmpty else { return "" }

        var text = raw

        // 0. 换行 / 空格类字符归一（必须先做，后续规则只处理 \n）
        text = normalizeLineEndings(text)
        text = normalizeSpaceCharacters(text)

        // 1. 连字（ligature）还原：ﬁ ﬂ ﬀ ﬃ ﬄ ﬅ ﬆ
        text = normalizeLigatures(text)

        // 2. 软连字符（U+00AD）：不可见但会截断单词，直接删除
        text = text.replacingOccurrences(of: "\u{00AD}", with: "")

        // 3. 连字符处理（顺序敏感）
        text = preserveKnownCompoundHyphenations(text)  // well-\nknown → well-known
        text = joinSoftHyphenations(text)               // experi-\nmental → experimental
        text = joinCompoundHyphenations(text)           // DNA-\nbinding → DNA-binding
        if options.joinsHyphenatedLineBreaksWithinLine {
            text = joinSoftHyphenationsWithinLine(text)
        }

        // 4. 行尾破折号 / 括号 / 引号 与下一行直接拼接（不插入空格）
        text = joinBrokenPunctuation(text)

        // 5. 段落结构归一 + 段内换行转空格
        text = reflowParagraphs(text)

        // 6. 标点前空格、括号内侧空格清理
        text = tidyPunctuationSpacing(text)

        // 7. 收尾
        text = collapseBlankLines(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 清洗参数。
    public struct Options: Sendable, Equatable {
        /// 是否合并「同一行内」被空格截断的单词（`experi- mental`）。
        /// 某些阅读器复制 PDF 时不产生换行，只产生空格；但该规则有误伤风险
        /// （如 `6- 8`、`p- value`），因此默认关闭。
        public var joinsHyphenatedLineBreaksWithinLine: Bool

        public init(joinsHyphenatedLineBreaksWithinLine: Bool = false) {
            self.joinsHyphenatedLineBreaksWithinLine = joinsHyphenatedLineBreaksWithinLine
        }

        public static let `default` = Options()
    }

    // MARK: - 步骤 0：字符归一

    /// `\r\n`、`\r`、Unicode 行分隔符 → `\n`
    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")   // LINE SEPARATOR
            .replacingOccurrences(of: "\u{2029}", with: "\n\n") // PARAGRAPH SEPARATOR
            .replacingOccurrences(of: "\u{0085}", with: "\n")   // NEL
    }

    /// 各类“看起来是空格”的字符统一为 ASCII 空格；但 **不** 动换行。
    static func normalizeSpaceCharacters(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { isSpaceLike($0) }) else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if isSpaceLike(scalar) {
                out.unicodeScalars.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func isSpaceLike(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009, 0x000B, 0x000C:                  // TAB / VT / FF
            return true
        case 0x00A0, 0x2007, 0x202F:                  // NBSP / FIGURE SPACE / NNBSP
            return true
        case 0x2000...0x200A, 0x205F:                 // EN QUAD … HAIR SPACE
            return true
        case 0x3000:                                  // IDEOGRAPHIC SPACE
            return true
        default:
            return false
        }
    }

    /// 连字（合字）还原。
    static func normalizeLigatures(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { ligatureMap[$0] != nil }) else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if let replacement = ligatureMap[scalar] {
                out.append(replacement)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static let ligatureMap: [Unicode.Scalar: String] = [
        "\u{FB00}": "ff",   // ﬀ
        "\u{FB01}": "fi",   // ﬁ
        "\u{FB02}": "fl",   // ﬂ
        "\u{FB03}": "ffi",  // ﬃ
        "\u{FB04}": "ffl",  // ﬄ
        "\u{FB05}": "st",   // ﬅ
        "\u{FB06}": "st",   // ﬆ
    ]

    // MARK: - 步骤 3：连字符还原

    /// 连字符集合：ASCII hyphen 与 U+2010 HYPHEN。
    /// 刻意排除 U+2011 NON-BREAKING HYPHEN（作者显式要求不可断行）。
    private static let hyphen = "\\-\u{2010}"

    /// 断行点（单个换行，且下一行不是空行 → 不跨段落合并）。
    private static let lineBreak = "[ \\t]*\\n(?![ \\t]*\\n)[ \\t]*"

    /// 学术写作中习惯保留连字符的前缀（`well-known`、`two-dimensional`）。
    ///
    /// 注意：这里只收录「合并后会变成非词」的前缀。像 `non-linear`、`multi-modal`、
    /// `inter-national`、`un-like` 这类合并后依然是合法英文词的情况，故意 **不** 收录，
    /// 交给 `joinSoftHyphenations` 去掉连字符（保留连字符反而会降低译文质量）。
    static let compoundPrefixes: Set<String> = [
        "well", "self", "cross", "high", "low", "long", "short", "mid",
        "all", "full", "half", "part", "open", "closed", "left", "right",
        "top", "bottom", "front", "back", "first", "second", "third",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "single", "double", "triple", "class", "level", "phase", "dose",
        "time", "age", "size", "shape", "risk",
    ]

    /// 连字符链条中的功能词。命中时保留连字符，避免 `state-of-the-art` 被粘成 `state-ofthe-art`。
    static let hyphenParticleKeep: Set<String> = [
        "of", "the", "to", "in", "and", "or", "on", "at", "by", "for", "with", "a", "an", "is", "are",
    ]

    /// 学术写作中习惯保留连字符的 **后缀**（`dose-dependent`、`cell-like`）。
    static let compoundSuffixes: Set<String> = [
        "type", "like", "based", "induced", "dependent", "independent", "specific",
        "related", "mediated", "driven", "associated", "free", "only", "scale",
        "level", "state", "order", "body", "step", "term", "time", "fold", "rich",
        "poor", "wide", "bound", "linked", "coupled", "derived", "adjusted", "matched",
        "controlled", "defined", "directed", "limited", "restricted", "resolved",
        "sensitive", "selective", "tolerant", "resistant", "deficient", "positive",
        "negative", "neutral", "biased", "aware", "oriented", "weighted", "normalized",
    ]

    /// 「合并成词」明显优于保留连字符的前缀。
    ///
    /// 命中的断点不会被 `preserveKnownCompoundHyphenations` 拦下，
    /// 而是交给 `joinSoftHyphenations` 直接去连字符（`non-linear` → `nonlinear`、
    /// `Un-like` → `Unlike`），因为这些形式在英文里才是标准写法。
    static let joinPreferredPrefixes: Set<String> = [
        "un", "re", "in", "im", "dis", "mis", "non", "pre", "post", "anti",
        "multi", "sub", "inter", "intra", "semi", "over", "under", "ultra",
        "micro", "macro", "nano", "pseudo", "quasi", "trans", "co", "de",
        "bi", "tri", "uni", "mono", "poly", "hyper", "hypo", "iso", "auto",
        "homo", "hetero", "bio", "geo", "neuro", "electro", "thermo", "hydro",
        "photo", "psycho", "socio", "techno", "dna", "rna", "self",
    ]

    /// 命中已知复合词前缀 / 后缀时保留连字符（并把断行收紧为 `-`）。
    static func preserveKnownCompoundHyphenations(_ text: String) -> String {
        let pattern = "([A-Za-z]{2,})[\(hyphen)]\(lineBreak)([A-Za-z]{2,})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }

        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var cursor = 0
        for match in matches {
            let left = ns.substring(with: match.range(at: 1))
            let right = ns.substring(with: match.range(at: 2))
            let leftKey = left.lowercased()
            let rightKey = right.lowercased()

            // 合并成词更优的前缀：交给后续去连字符规则
            guard !joinPreferredPrefixes.contains(leftKey) else { continue }

            let shouldKeepHyphen = compoundPrefixes.contains(leftKey)
                || compoundSuffixes.contains(rightKey)
                || hyphenParticleKeep.contains(leftKey)
                || hyphenParticleKeep.contains(rightKey)
            guard shouldKeepHyphen else { continue }

            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "\(left)-\(right)"
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// 跨行软连字符：`experi-\n mental` → `experimental`
    ///
    /// 左侧允许「首字母大写 + 至少一个小写字母」（`Un-` → `Unlike`），
    /// 但纯缩写（`DNA-`、`X-`）不会被并入，因为它们通常是真正的复合词词首。
    /// 右侧要求小写字母开头，也是为了避免把 `Table-\n1` 这类编号当成单词。
    static func joinSoftHyphenations(_ text: String) -> String {
        text.replacingOccurrences(
            of: "([A-Z][a-z]{1,}|[a-z]{2,})[\(hyphen)]\(lineBreak)([a-z]{2,})",
            with: "$1$2",
            options: .regularExpression
        )
    }

    /// 跨行复合词：`non-\nNewtonian` → `non-Newtonian`（保留连字符）
    ///
    /// 覆盖两种情况：右侧以大写字母/数字开头，或左侧以大写缩写结尾。
    static func joinCompoundHyphenations(_ text: String) -> String {
        var text = text
        text = text.replacingOccurrences(
            of: "([A-Za-z]{1,})[\(hyphen)]\(lineBreak)([A-Z0-9][A-Za-z0-9]*)",
            with: "$1-$2",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "([A-Z]{2,})[\(hyphen)]\(lineBreak)([a-z0-9]+)",
            with: "$1-$2",
            options: .regularExpression
        )
        return text
    }

    /// 同一行内被空格截断的单词：`experi- mental` → `experimental`（默认不启用）
    static func joinSoftHyphenationsWithinLine(_ text: String) -> String {
        text.replacingOccurrences(
            of: "([a-z]{3,})[\(hyphen)][ \\t]+([a-z]{2,})",
            with: "$1$2",
            options: .regularExpression
        )
    }

    // MARK: - 步骤 4：断行标点拼接

    /// 行尾的破折号 / 左括号 / 左引号，和下一行拼接时不插入空格。
    /// 下一行为空行时不拼接（段落边界优先）。
    static func joinBrokenPunctuation(_ text: String) -> String {
        text.replacingOccurrences(
            of: "([\u{2014}\u{2013}(\\[\\{\u{201C}\u{2018}])\(lineBreak)",
            with: "$1",
            options: .regularExpression
        )
    }

    // MARK: - 步骤 5：段落归一与重排

    /// 把文本切分为段落（空行分隔），段内硬换行 → 单空格。
    static func reflowParagraphs(_ text: String) -> String {
        splitParagraphs(text)
            .map { reflowSingleParagraph($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// 以「空行（含仅由空格组成的行）」为界切段。
    static func splitParagraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
        return paragraphs
    }

    /// 单个段落内部：换行 → 空格，压缩连续空格。
    static func reflowSingleParagraph(_ paragraph: String) -> String {
        paragraph
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 步骤 6：标点空格

    /// 去掉标点符号前的空格、括号内侧空格，并修复与基准字母分离的组合附加符号。
    static func tidyPunctuationSpacing(_ text: String) -> String {
        var text = removeSpaceBeforeCombiningMarks(text)
        // 半角标点前的空格：`et al .` → `et al.`
        text = text.replacingOccurrences(
            of: "[ \\t]+([,.;:!?%\\)\\]\\}])",
            with: "$1",
            options: .regularExpression
        )
        // 全角标点前的空格
        text = text.replacingOccurrences(
            of: "[ \\t]+([，。；：！？、）】》」』])",
            with: "$1",
            options: .regularExpression
        )
        // 左括号 / 左引号后的空格
        text = text.replacingOccurrences(
            of: "([\\(\\[\\{\u{201C}\u{2018}])[ \\t]+",
            with: "$1",
            options: .regularExpression
        )
        return text
    }

    /// PDF 文本抽取常见瑕疵：基准字母与组合附加符号之间被插入了空格（`e` + ` ` + U+0301）。
    ///
    /// 由于「空格 + 组合符号」在 Swift 里是一个字形簇，正则无法处理，因此在
    /// Unicode 标量层面直接删除该空格。
    static func removeSpaceBeforeCombiningMarks(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { isCombiningMark($0) }) else { return text }
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if isCombiningMark(scalar), let last = scalars.last, last == " " || last == "\t" {
                scalars.removeLast()
            }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036F,   // Combining Diacritical Marks
             0x1AB0...0x1AFF,   // Combining Diacritical Marks Extended
             0x1DC0...0x1DFF,   // Combining Diacritical Marks Supplement
             0x20D0...0x20FF,   // Combining Diacritical Marks for Symbols
             0xFE20...0xFE2F:   // Combining Half Marks
            return true
        default:
            return false
        }
    }

    static func collapseBlankLines(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
    }
}

// MARK: - 诊断（供设置界面 / 测试使用）

nonisolated public extension TextSanitizer {

    /// 清洗前后差异的量化指标，用于在 UI 上展示“清洗引擎工作了没有”。
    struct Report: Sendable, Equatable {
        public var inputCharacterCount: Int
        public var outputCharacterCount: Int
        public var paragraphCount: Int
        public var joinedLineBreaks: Int
        public var restoredLigatures: Int
        public var removedSoftHyphens: Int
    }

    static func report(on raw: String) -> Report {
        let cleaned = cleanAcademicText(raw)
        return Report(
            inputCharacterCount: raw.count,
            outputCharacterCount: cleaned.count,
            paragraphCount: cleaned.isEmpty ? 0 : cleaned.components(separatedBy: "\n\n").count,
            joinedLineBreaks: max(0, raw.components(separatedBy: "\n").count - cleaned.components(separatedBy: "\n").count),
            restoredLigatures: raw.unicodeScalars.filter { ligatureMap[$0] != nil }.count,
            removedSoftHyphens: raw.unicodeScalars.filter { $0.value == 0x00AD }.count
        )
    }
}
