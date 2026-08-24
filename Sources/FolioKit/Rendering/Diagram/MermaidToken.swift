import Foundation

/// The lexical layer both Mermaid parsers share: statement splitting, label decoding, and the
/// two scanners that do the real work — one for bracketed node shapes, one for edge tokens.
///
/// Deliberately hand-written rather than `NSRegularExpression`. Mermaid's own grammar is a JISON
/// tangle, real documents contain `A-->|"yes, ok"|B` and `A-.->B` with no spaces anywhere, and a
/// regex over that is both slower and far harder to make total. A scanner can simply refuse, and
/// refusing is a supported outcome here: the block falls back to a source card.
///
/// Known gap, stated rather than hidden: backtick-delimited markdown strings in labels are not
/// interpreted. The backticks come through literally.
enum MermaidToken {

    struct Statement {
        let text: String
        /// 1-based line in the fence, for diagnostics only. Never reaches geometry.
        let line: Int
    }

    // MARK: Statements

    /// Splits a Mermaid block into trimmed, comment-free statements.
    ///
    /// `%%{init: …}%%` directives are dropped with the comments: they only theme, and honouring a
    /// declared theme is exactly what `Theme.swift` forbids.
    static func statements(in source: String) -> [Statement] {
        var result: [Statement] = []
        let normalised = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for (offset, rawLine) in normalised.components(separatedBy: "\n").enumerated() {
            let stripped = stripComment(rawLine)
            for piece in splitStatements(stripped) {
                let text = piece.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                result.append(Statement(text: text, line: offset + 1))
            }
        }
        return result
    }

    /// Removes a `%%` comment, respecting quotes so a label containing `%%` survives.
    private static func stripComment(_ line: String) -> String {
        let chars = Array(line)
        var inQuote = false
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\"" { inQuote.toggle() }
            if !inQuote, c == "%", index + 1 < chars.count, chars[index + 1] == "%" {
                return String(chars[0..<index])
            }
            index += 1
        }
        return line
    }

    /// Splits on `;` outside quotes and outside brackets. A `;` inside `A["a; b"]` is text.
    private static func splitStatements(_ line: String) -> [String] {
        guard line.contains(";") else { return [line] }
        var pieces: [String] = []
        var current = ""
        var inQuote = false
        var depth = 0
        for c in line {
            if c == "\"" { inQuote.toggle() }
            if !inQuote {
                if c == "[" || c == "(" || c == "{" { depth += 1 }
                if c == "]" || c == ")" || c == "}" { depth = max(0, depth - 1) }
                if c == ";", depth == 0 {
                    pieces.append(current)
                    current = ""
                    continue
                }
            }
            current.append(c)
        }
        pieces.append(current)
        return pieces
    }

    // MARK: Labels

    /// Decodes a raw bracket body into display lines: quotes stripped, `<br>` honoured, Mermaid's
    /// `#…;` entities resolved, whitespace collapsed per line.
    static func decodeLabel(_ raw: String) -> DiagramGraph.Label {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }

        for tag in ["<br/>", "<br />", "<br>", "<BR/>", "<BR />", "<BR>"] {
            text = text.replacingOccurrences(of: tag, with: "\n")
        }
        text = decodeEntities(text)

        let lines = text.components(separatedBy: "\n").map { line -> String in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        return DiagramGraph.Label(lines: lines.isEmpty ? [""] : lines)
    }

    /// Mermaid escapes characters its grammar would otherwise eat, using `#name;` and `#NN;`
    /// rather than HTML's `&`, because `&` is an edge operator.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("#") else { return text }
        let named: [String: String] = [
            "quot": "\"", "amp": "&", "lt": "<", "gt": ">",
            "semi": ";", "nbsp": "\u{00a0}", "colon": ":", "num": "#",
        ]
        var result = ""
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "#",
                  let close = chars[index...].firstIndex(of: ";"),
                  close - index <= 8 else {
                result.append(chars[index])
                index += 1
                continue
            }
            let body = String(chars[(index + 1)..<close])
            if let replacement = named[body] {
                result.append(replacement)
            } else if let code = UInt32(body), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            } else {
                result.append(contentsOf: chars[index...close])
            }
            index = close + 1
        }
        return result
    }

    // MARK: Bracket scanner

    struct BracketScan {
        let shape: DiagramGraph.Shape
        let body: String
        /// Index just past the closing bracket.
        let end: Int
    }

    /// One opener, and the closers that may end it. The skew family is the only one where the
    /// closer decides the shape: `[/x/]` is a parallelogram but `[/x\]` is a trapezoid.
    private struct Rule {
        let open: String
        let closers: [(String, DiagramGraph.Shape)]
    }

    /// Longest opener first — `[[` must be tried before `[`, or every subroutine reads as a rect
    /// containing a stray bracket.
    private static let rules: [Rule] = [
        Rule(open: "(((", closers: [(")))", .doubleCircle)]),
        Rule(open: "[[", closers: [("]]", .subroutine)]),
        Rule(open: "[(", closers: [(")]", .cylinder)]),
        Rule(open: "[/", closers: [("/]", .parallelogram), ("\\]", .trapezoid)]),
        Rule(open: "[\\", closers: [("\\]", .parallelogramAlt), ("/]", .trapezoidAlt)]),
        Rule(open: "([", closers: [("])", .stadium)]),
        Rule(open: "((", closers: [("))", .circle)]),
        Rule(open: "{{", closers: [("}}", .hexagon)]),
        Rule(open: "[", closers: [("]", .rect)]),
        Rule(open: "(", closers: [(")", .rounded)]),
        Rule(open: "{", closers: [("}", .diamond)]),
        Rule(open: ">", closers: [("]", .asymmetric)]),
    ]

    /// Reads a shape bracket beginning at `start`, or nil if none begins there.
    ///
    /// Quote-aware, and depth-counted over the opener so `A[a [b] c]` closes where the author
    /// meant it to.
    static func scanBracketed(_ chars: [Character], from start: Int) -> BracketScan? {
        guard start < chars.count else { return nil }
        for rule in rules {
            guard matches(chars, at: start, rule.open) else { continue }
            var depth = 1
            var index = start + rule.open.count
            var inQuote = false
            while index < chars.count {
                if chars[index] == "\"" {
                    inQuote.toggle()
                    index += 1
                    continue
                }
                if inQuote { index += 1; continue }
                if matches(chars, at: index, rule.open) {
                    depth += 1
                    index += rule.open.count
                    continue
                }
                var closed = false
                for (closer, shape) in rule.closers where matches(chars, at: index, closer) {
                    depth -= 1
                    if depth == 0 {
                        let body = String(chars[(start + rule.open.count)..<index])
                        return BracketScan(shape: shape, body: body, end: index + closer.count)
                    }
                    index += closer.count
                    closed = true
                    break
                }
                if closed { continue }
                index += 1
            }
            // An opener with no closer is malformed; refuse rather than guess an extent.
            return nil
        }
        return nil
    }

    private static func matches(_ chars: [Character], at index: Int, _ token: String) -> Bool {
        let needle = Array(token)
        guard index + needle.count <= chars.count else { return false }
        for offset in 0..<needle.count where chars[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    // MARK: Edge scanner

    struct EdgeScan {
        let stroke: DiagramGraph.Stroke
        let head: DiagramGraph.Cap
        let tail: DiagramGraph.Cap
        let minRankSpan: Int
        /// Label written between two halves of the token (`A -- text --> B`), if any.
        let inlineLabel: String?
        let end: Int
    }

    /// Reads an edge token at `start`, including the `A -- text --> B` split form, or nil.
    static func scanEdge(_ chars: [Character], from start: Int) -> EdgeScan? {
        if let split = scanSplitEdge(chars, from: start) { return split }
        return scanSimpleEdge(chars, from: start)
    }

    /// `A -- text --> B`, `A == text ==> B`, `A -. text .-> B`.
    ///
    /// The opener is exactly the two-character stem with no cap and nothing that could continue a
    /// plain token after it, which is what keeps `-->`, `---` and `-.->` out of this path.
    private static func scanSplitEdge(_ chars: [Character], from start: Int) -> EdgeScan? {
        guard start + 1 < chars.count else { return nil }
        let stem = String(chars[start...(start + 1)])
        let continuation: Set<Character>
        switch stem {
        case "--": continuation = ["-", ">", ".", "o", "x"]
        case "==": continuation = ["=", ">"]
        case "-.": continuation = ["-"]
        default: return nil
        }
        let afterStem = start + 2
        guard afterStem < chars.count, !continuation.contains(chars[afterStem]) else { return nil }

        var probe = afterStem
        while probe < chars.count {
            if chars[probe] == "\"" {
                // Skip a quoted run so a label containing `-->` cannot close its own edge.
                probe += 1
                while probe < chars.count, chars[probe] != "\"" { probe += 1 }
                probe += 1
                continue
            }
            if let closer = scanSimpleEdge(chars, from: probe) {
                let label = String(chars[afterStem..<probe]).trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { return nil }
                return EdgeScan(stroke: closer.stroke, head: closer.head, tail: closer.tail,
                                minRankSpan: closer.minRankSpan, inlineLabel: label,
                                end: closer.end)
            }
            probe += 1
        }
        return nil
    }

    private static func scanSimpleEdge(_ chars: [Character], from start: Int) -> EdgeScan? {
        var index = start
        var tail = DiagramGraph.Cap.none

        // A leading cap only counts when a body follows it directly, which is what tells a node
        // named `o` apart from a circle cap: `A o--o B` reads as a circle tail, `o --> B` does
        // not. `o-->B` is genuinely ambiguous and resolves as a cap, the same way Mermaid's own
        // grammar resolves it.
        if index < chars.count, let cap = cap(for: chars[index]), chars[index] != ">",
           index + 1 < chars.count, isBodyStart(chars[index + 1]) {
            tail = cap
            index += 1
        }

        let bodyStart = index
        var stroke: DiagramGraph.Stroke
        var dotCount = 0

        if matches(chars, at: index, "~~~") {
            stroke = .invisible
            index += 3
        } else if index < chars.count, chars[index] == "=" {
            let run = runLength(chars, from: index, of: "=")
            guard run >= 2 else { return nil }
            stroke = .thick
            index += run
        } else if index < chars.count, chars[index] == "-" || chars[index] == "." {
            var sawDots = false
            var sawDash = false
            while index < chars.count {
                if chars[index] == "-" {
                    index += runLength(chars, from: index, of: "-")
                    sawDash = true
                } else if chars[index] == "." {
                    let run = runLength(chars, from: index, of: ".")
                    // A dot run only continues the token when a dash follows it.
                    guard index + run < chars.count, chars[index + run] == "-" else { break }
                    dotCount += run
                    sawDots = true
                    index += run
                } else {
                    break
                }
            }
            guard sawDash else { return nil }
            stroke = sawDots ? .dotted : .solid
            if !sawDots, index - bodyStart < 2 { return nil }
        } else {
            return nil
        }

        var head = DiagramGraph.Cap.none
        if index < chars.count, stroke != .invisible {
            if chars[index] == ">" {
                head = .arrow
                index += 1
            } else if let cap = cap(for: chars[index]), cap != .arrow {
                head = cap
                index += 1
            }
        }

        // Mermaid measures link length in characters, not dashes: `-->` and `---` are both one
        // rank, `--->` and `----` are both two. Dotted links count their dots instead.
        let span = stroke == .dotted
            ? max(1, min(8, dotCount))
            : max(1, min(8, (index - bodyStart) - 2))

        return EdgeScan(stroke: stroke, head: head, tail: tail, minRankSpan: span,
                        inlineLabel: nil, end: index)
    }

    private static func cap(for c: Character) -> DiagramGraph.Cap? {
        switch c {
        case "o": return .circle
        case "x": return .cross
        case "<", ">": return .arrow
        default: return nil
        }
    }

    private static func isBodyStart(_ c: Character) -> Bool {
        c == "-" || c == "=" || c == "~"
    }

    private static func runLength(_ chars: [Character], from index: Int, of c: Character) -> Int {
        var count = 0
        while index + count < chars.count, chars[index + count] == c { count += 1 }
        return count
    }

    // MARK: Pipe labels

    /// Reads `|text|` immediately after an edge token, returning the text and the new index.
    static func scanPipeLabel(_ chars: [Character], from start: Int) -> (String, Int)? {
        var index = start
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        guard index < chars.count, chars[index] == "|" else { return nil }
        var probe = index + 1
        var inQuote = false
        while probe < chars.count {
            if chars[probe] == "\"" { inQuote.toggle() }
            if chars[probe] == "|", !inQuote {
                return (String(chars[(index + 1)..<probe]), probe + 1)
            }
            probe += 1
        }
        return nil
    }

    /// Reads a bare identifier: everything up to whitespace, a bracket, an edge character, `&`,
    /// or a `:::` class marker.
    static func scanIdentifier(_ chars: [Character], from start: Int) -> (String, Int)? {
        var index = start
        var text = ""
        while index < chars.count {
            let c = chars[index]
            if c == "\"" {
                // A quoted id, which Mermaid allows for ids containing spaces.
                var probe = index + 1
                while probe < chars.count, chars[probe] != "\"" {
                    text.append(chars[probe])
                    probe += 1
                }
                index = min(probe + 1, chars.count)
                continue
            }
            // `:` ends an id in both dialects: `A:::hot` is a class marker, `Idle : waiting` is
            // a state description.
            if c.isWhitespace || c == "&" || c == "|" || c == ":" { break }
            // A bracket — opener or closer — always ends an id, whether or not it turns out to
            // be a well-formed shape. Deciding this *before* `scanBracketed` is what makes
            // `A[unclosed --> B` fail the statement instead of declaring a node called
            // `A[unclosed`, and `]]] --> [[[` fail instead of declaring one called `]]]`.
            if "[](){}<>".contains(c) { break }
            if scanBracketed(chars, from: index) != nil { break }
            if scanSimpleEdge(chars, from: index) != nil { break }
            text.append(c)
            index += 1
        }
        return text.isEmpty ? nil : (text, index)
    }
}
