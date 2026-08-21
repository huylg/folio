import AppKit

/// Character-scanner producing classified token spans for a source line.
///
/// The tokenizer is emit-agnostic: `attributed(_:language:metrics:)` maps tokens to
/// attributed-string colors for the native reading pane, and `highlight(_:language:)` is a
/// transitional adapter that renders them as HTML spans for the legacy renderer.
public enum SyntaxHighlighter {

    private static let keywords: [String: Set<String>] = {
        let python: Set<String> = ["def", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or",
                                   "import", "from", "as", "class", "with", "try", "except", "finally", "raise",
                                   "lambda", "yield", "pass", "break", "continue", "None", "True", "False", "async", "await", "global", "del", "is", "assert"]
        let swift: Set<String> = ["func", "let", "var", "if", "else", "guard", "return", "for", "while", "in",
                                  "import", "class", "struct", "enum", "protocol", "extension", "switch", "case",
                                  "default", "break", "continue", "throw", "throws", "try", "catch", "defer",
                                  "init", "deinit", "self", "super", "nil", "true", "false", "static", "final",
                                  "private", "public", "internal", "open", "override", "where", "some", "any", "async", "await", "lazy", "weak", "typealias", "associatedtype"]
        let js: Set<String> = ["function", "const", "let", "var", "if", "else", "return", "for", "while", "of", "in",
                               "import", "export", "from", "class", "extends", "new", "this", "switch", "case",
                               "default", "break", "continue", "throw", "try", "catch", "finally", "async", "await",
                               "yield", "null", "undefined", "true", "false", "typeof", "instanceof", "delete", "void", "interface", "type", "enum", "implements", "readonly", "static", "public", "private", "protected"]
        let c: Set<String> = ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed",
                              "struct", "union", "enum", "typedef", "const", "static", "extern", "inline",
                              "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
                              "return", "goto", "sizeof", "auto", "template", "typename", "namespace", "using",
                              "class", "public", "private", "protected", "virtual", "override", "new", "delete", "nullptr", "true", "false"]
        let shell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                                  "function", "in", "return", "exit", "local", "export", "echo", "set", "source"]
        let rust: Set<String> = ["fn", "let", "mut", "if", "else", "match", "loop", "while", "for", "in", "return",
                                 "impl", "trait", "struct", "enum", "pub", "use", "mod", "crate", "self", "Self",
                                 "const", "static", "ref", "move", "async", "await", "dyn", "where", "unsafe", "true", "false", "Some", "None", "Ok", "Err"]
        let ruby: Set<String> = ["def", "end", "if", "elsif", "else", "unless", "case", "when", "while", "until",
                                 "for", "in", "do", "return", "class", "module", "require", "include", "attr_accessor",
                                 "begin", "rescue", "ensure", "raise", "yield", "self", "nil", "true", "false", "puts", "lambda", "proc"]
        let go: Set<String> = ["func", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else",
                               "for", "range", "switch", "case", "default", "break", "continue", "return", "go",
                               "defer", "select", "package", "import", "nil", "true", "false", "make", "new"]
        let sql: Set<String> = ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update",
                                "set", "delete", "create", "table", "join", "left", "right", "inner", "outer", "on",
                                "group", "by", "order", "having", "limit", "offset", "as", "distinct", "null", "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "AS", "DISTINCT", "NULL"]
        return [
            "python": python, "py": python,
            "swift": swift,
            "javascript": js, "js": js, "typescript": js, "ts": js, "tsx": js, "jsx": js,
            "c": c, "cpp": c, "c++": c, "objc": c, "objective-c": c, "java": c, "kotlin": c, "cs": c, "csharp": c,
            "bash": shell, "sh": shell, "zsh": shell, "shell": shell, "fish": shell,
            "rust": rust, "rs": rust,
            "ruby": ruby, "rb": ruby,
            "go": go, "golang": go,
            "sql": sql,
        ]
    }()

    private static let lineCommentPrefix: [String: String] = [
        "python": "#", "py": "#", "bash": "#", "sh": "#", "zsh": "#", "shell": "#", "fish": "#",
        "ruby": "#", "rb": "#", "yaml": "#", "toml": "#", "r": "#",
        "swift": "//", "javascript": "//", "js": "//", "typescript": "//", "ts": "//", "tsx": "//", "jsx": "//",
        "c": "//", "cpp": "//", "c++": "//", "java": "//", "kotlin": "//", "objc": "//", "cs": "//", "csharp": "//",
        "rust": "//", "rs": "//", "go": "//", "golang": "//",
        "sql": "--",
    ]
    // MARK: - Tokenizing

    /// One classified span of a source line, expressed as a character offset range so the
    /// caller can apply either attributed-string attributes or HTML spans.
    public struct Token: Equatable {
        public let range: Range<String.Index>
        public let kind: TokenClass
    }

    public enum TokenClass: Equatable, Hashable, CaseIterable {
        case keyword, function, string, number, comment
    }

    /// Classifies `code` line by line. Returns one array of tokens per line, in source order,
    /// covering only the spans that carry a class — unclassified text is plain.
    ///
    /// This is the shared entry point: the attributed-string builder maps tokens to colors,
    /// and the raw-markdown tokenizer delegates to it for the interior of fenced blocks.
    public static func tokenize(_ code: String, language lang: String?) -> [[Token]] {
        let language = (lang ?? "").lowercased()
        let kw = keywords[language]
        let comment = lineCommentPrefix[language]
        return code.components(separatedBy: "\n").map {
            tokens(in: $0, keywords: kw, commentPrefix: comment)
        }
    }

    private static func tokens(in line: String, keywords: Set<String>?, commentPrefix: String?) -> [Token] {
        // A line comment ends the line. The quote-parity check avoids treating a '#' or '//'
        // inside a string literal as the start of a comment.
        if let prefix = commentPrefix, let r = line.range(of: prefix) {
            let before = line[..<r.lowerBound]
            let quotes = before.filter { $0 == "\"" || $0 == "'" }.count
            if quotes % 2 == 0 {
                var result = scan(line, upTo: r.lowerBound, keywords: keywords)
                result.append(Token(range: r.lowerBound..<line.endIndex, kind: .comment))
                return result
            }
        }
        return scan(line, upTo: line.endIndex, keywords: keywords)
    }

    private static func scan(_ line: String, upTo end: String.Index, keywords: Set<String>?) -> [Token] {
        var result: [Token] = []
        var i = line.startIndex

        while i < end {
            let ch = line[i]

            // String literals, including escapes.
            if ch == "\"" || ch == "'" || ch == "`" {
                let quote = ch
                var j = line.index(after: i)
                while j < end, line[j] != quote {
                    if line[j] == "\\" { j = line.index(after: j) }
                    if j < end { j = line.index(after: j) }
                }
                if j < end { j = line.index(after: j) }
                result.append(Token(range: i..<j, kind: .string))
                i = j
                continue
            }

            // Numeric literals, including a leading sign and hex digits.
            if ch.isNumber || (ch == "-" && isTokenBoundary(line, at: i)
                                && line.index(after: i) < end && line[line.index(after: i)].isNumber) {
                guard isTokenBoundary(line, at: i) else {
                    i = line.index(after: i)
                    continue
                }
                var j = ch == "-" ? line.index(after: i) : i
                while j < end,
                      line[j].isNumber || line[j] == "." || line[j] == "_"
                        || line[j] == "x" || line[j].isHexDigit {
                    j = line.index(after: j)
                }
                result.append(Token(range: i..<j, kind: .number))
                i = j
                continue
            }

            // Identifiers: keyword, or a call site if followed by an open paren.
            if ch.isLetter || ch == "_" {
                var j = i
                while j < end, line[j].isLetter || line[j].isNumber || line[j] == "_" {
                    j = line.index(after: j)
                }
                let word = String(line[i..<j])
                if let keywords, keywords.contains(word) {
                    result.append(Token(range: i..<j, kind: .keyword))
                } else if j < end, line[j] == "(" {
                    result.append(Token(range: i..<j, kind: .function))
                }
                i = j
                continue
            }

            i = line.index(after: i)
        }
        return result
    }

    private static func isTokenBoundary(_ line: String, at i: String.Index) -> Bool {
        guard i > line.startIndex else { return true }
        let prev = line[line.index(before: i)]
        return !(prev.isLetter || prev.isNumber || prev == "_")
    }

    // MARK: - Attributed output

    /// Builds an attributed string for a code block, one paragraph per line.
    ///
    /// Code is emitted as real text rather than an attachment view, so ⌘F can find it,
    /// a few lines can be selected out of a block, and VoiceOver reads it line by line.
    public static func attributed(
        _ code: String,
        language: String?,
        metrics: DocumentMetrics
    ) -> NSAttributedString {
        let lines = code.components(separatedBy: "\n")
        let perLine = tokenize(code, language: language)
        let out = NSMutableAttributedString()

        for (index, line) in lines.enumerated() {
            let style = metrics.paragraphStyle(
                for: .codeLine(isFirst: index == 0, isLast: index == lines.count - 1)
            )
            let piece = NSMutableAttributedString(
                string: line,
                attributes: [
                    .font: metrics.ramp.mono(),
                    .foregroundColor: Ink.body,
                    .paragraphStyle: style,
                    .folioBlockKind: BlockKind.codeLine(isFirst: index == 0,
                                                        isLast: index == lines.count - 1),
                ]
            )
            for token in perLine[index] {
                let nsRange = NSRange(token.range, in: line)
                piece.addAttributes(
                    [.foregroundColor: Ink.syntax(token.kind),
                     .folioInlineRole: InlineRole.syntax(token.kind)],
                    range: nsRange
                )
            }
            out.append(piece)
            if index < lines.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

}
