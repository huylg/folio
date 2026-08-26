import Foundation
import Markdown

public struct OutlineEntry {
    public let level: Int          // 1...6
    public let title: String
    public let anchor: String
}

public struct DocumentStats {
    public var words = 0
    public var readMinutes: Int { max(1, Int((Double(words) / 240.0).rounded())) }
    public var equations = 0
    public var codeBlocks = 0
    /// Mermaid fences the *author* wrote, not blocks Folio drew. A stat that moved when a reader
    /// flipped `renderDiagrams` would make the meta line lie about the document; which of them
    /// were drawn is in the dump's BLOCKS section.
    public var diagrams = 0
    public var citations = 0
    public var sectionCount = 0    // number of top-level (h1/h2) sections
}

/// A parsed, read-only markdown document.
public final class MarkdownDocument {
    public let url: URL
    /// The project root the document lives in — see `ProjectRoot`. Computed once at open;
    /// the document is an immutable snapshot, so a `.git` created later is seen on reopen.
    public let rootURL: URL
    public let source: String
    public let frontmatter: Frontmatter
    public let body: String
    public let markup: Document
    public let outline: [OutlineEntry]
    public let stats: DocumentStats
    public let modificationDate: Date?

    public init(url: URL) throws {
        self.url = url
        self.rootURL = ProjectRoot.detect(for: url)
        self.source = try String(contentsOf: url, encoding: .utf8)
        let (fm, body) = Frontmatter.parse(source)
        self.frontmatter = fm
        // Pull display-math blocks out before parsing so `$$…$$` survives as math fences.
        self.body = MarkdownDocument.hoistDisplayMath(body)
        self.markup = Document(parsing: self.body)
        self.modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        var walker = AnalysisWalker()
        walker.visit(markup)
        self.outline = walker.outline
        var stats = walker.stats
        stats.citations = MarkdownDocument.countCitations(in: body)
        self.stats = stats
    }

    public var title: String {
        if case .scalar(let t)? = frontmatter.values["title"] { return t }
        if let h1 = outline.first(where: { $0.level == 1 }) { return h1.title }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `$$ … $$` on their own lines become ```math fences so the renderer can treat them as blocks.
    private static func hoistDisplayMath(_ text: String) -> String {
        var out: [String] = []
        var mathBuffer: [String] = []
        var inMath = false
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !inMath, t.hasPrefix("```") || t.hasPrefix("~~~") {
                inCode.toggle()
                out.append(line)
                continue
            }
            if !inMath, !inCode, t == "$$" || (t.hasPrefix("$$") && t.hasSuffix("$$") && t.count > 4) {
                if t.count > 4 {
                    // single-line $$ x = y $$
                    let inner = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                    out.append("```math")
                    out.append(inner)
                    out.append("```")
                } else {
                    inMath = true
                    mathBuffer = []
                }
                continue
            }
            if inMath {
                if t == "$$" {
                    inMath = false
                    out.append("```math")
                    out.append(contentsOf: mathBuffer)
                    out.append("```")
                } else {
                    mathBuffer.append(line)
                }
                continue
            }
            out.append(line)
        }
        if inMath { out.append(contentsOf: ["$$"] + mathBuffer) }
        return out.joined(separator: "\n")
    }

    private static func countCitations(in text: String) -> Int {
        var count = 0
        // footnote refs [^x] and pandoc citations [@x]
        for pattern in [#"\[\^[^\]]+\]"#, #"\[@[^\]]+\]"#] {
            if let re = try? NSRegularExpression(pattern: pattern) {
                count += re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            }
        }
        return count
    }
}

/// Builds outline + stats in one AST pass.
private struct AnalysisWalker: MarkupWalker {
    var outline: [OutlineEntry] = []
    var stats = DocumentStats()
    private var usedAnchors: Set<String> = []

    mutating func visitHeading(_ heading: Heading) {
        let title = heading.plainText
        var anchor = Self.slug(title)
        var n = 1
        while usedAnchors.contains(anchor) { n += 1; anchor = Self.slug(title) + "-\(n)" }
        usedAnchors.insert(anchor)
        outline.append(OutlineEntry(level: heading.level, title: title, anchor: anchor))
        if heading.level <= 2 { stats.sectionCount += 1 }
        descendInto(heading)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let lang = (codeBlock.language ?? "").lowercased()
        if lang == "math" || lang == "latex" || lang == "tex" {
            stats.equations += 1
        } else if lang == "mermaid" {
            stats.diagrams += 1
        } else {
            stats.codeBlocks += 1
        }
    }

    mutating func visitText(_ text: Markdown.Text) {
        stats.words += text.string.split(whereSeparator: { $0.isWhitespace }).count
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        stats.words += inlineCode.code.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "section" : trimmed
    }
}
