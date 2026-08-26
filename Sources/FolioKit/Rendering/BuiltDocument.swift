import AppKit

/// The output of `AttributedDocumentBuilder`: the styled text plus every index the UI needs
/// to navigate it.
public struct BuiltDocument {
    public let attributed: NSAttributedString

    /// Anchor slug → the heading's character range. Slugs come from `MarkdownDocument.outline`,
    /// so in-document `#fragment` links resolve against the same names the sidebar shows.
    public let anchors: [String: NSRange]

    /// One entry per `MarkdownDocument.outline` entry, in the same order.
    ///
    /// This alignment is the fix for two long-standing off-by-one bugs. The previous
    /// JavaScript scroll-spy maintained its own heading enumeration (`#doc h1..h4`), which
    /// both *included* a synthesized title the outline did not contain and *excluded* h5/h6
    /// that it did — so the sidebar highlighted the wrong row on most real documents.
    /// Here the synthesized title is deliberately absent and every level 1–6 is present, so
    /// `headings[i].outlineIndex == i` always holds.
    public let headings: [HeadingRange]

    /// Indices into `headings` for level ≤ 2, matching how `DocumentStats.sectionCount` is
    /// computed, so the status bar's "Section 3 of 6" can no longer disagree with itself.
    public let sectionIndices: [Int]

    /// Top-level block ranges, used by focus mode and the code-card chrome.
    public let blocks: [BlockRecord]

    /// What the reading pane actually renders: one component per top-level piece of the
    /// document, each with its own view and its own selection.
    ///
    /// Derived from `blocks`, so the two can never disagree about where a block starts.
    public let components: [DocumentComponent]

    public init(
        attributed: NSAttributedString,
        anchors: [String: NSRange],
        headings: [HeadingRange],
        sectionIndices: [Int],
        blocks: [BlockRecord],
        components: [DocumentComponent]
    ) {
        self.attributed = attributed
        self.anchors = anchors
        self.headings = headings
        self.sectionIndices = sectionIndices
        self.blocks = blocks
        self.components = components
    }

    public var plainText: String { attributed.string }

    /// Index into `headings` of the last heading at or above `location`.
    public func headingIndex(at location: Int) -> Int? {
        var result: Int?
        for (index, heading) in headings.enumerated() {
            if heading.range.location <= location { result = index } else { break }
        }
        return result
    }

    /// The component containing `location`, for anchors and restored scroll positions.
    public func componentIndex(containing location: Int) -> Int? {
        if let exact = components.firstIndex(where: {
            $0.range.location <= location && location < NSMaxRange($0.range)
        }) { return exact }
        // Past the end of the last component, or on a separator between two: the component that
        // starts at or before the location is the one the reader means.
        return components.lastIndex { $0.range.location <= location }
    }

    /// The character range of the section opened by outline entry `index`: from the heading
    /// itself to the next heading at the same or a shallower level, else the end of the
    /// document. Relies on the `headings[i].outlineIndex == i` alignment documented above.
    public func sectionRange(forOutlineIndex index: Int) -> NSRange? {
        guard headings.indices.contains(index) else { return nil }
        let start = headings[index].range.location
        let level = headings[index].level
        let end = headings[(index + 1)...].first { $0.level <= level }?.range.location
            ?? attributed.length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The block containing `location`.
    public func block(at location: Int) -> BlockRecord? {
        blocks.last { $0.range.location <= location && location < NSMaxRange($0.range) }
            ?? blocks.last { $0.range.location <= location }
    }
}

/// What a block widget needs in order to build its view. Kept separate from the view so the
/// payload survives attachment-view recycling and can be re-measured without a live view.
public enum BlockPayload {
    case table(TableSpec)
    case math(latex: String, number: Int)
    /// The parse result travels with the source so "can this be drawn" is decided once, by the
    /// builder, and every consumer reads the same answer. A nil graph is an honest source card.
    case diagram(source: String, graph: DiagramGraph?)
    case frontmatter(Frontmatter)
    case image(source: String, alt: String, base: URL)
    /// A verbatim HTML block. Shown as a source card: silently dropping a whole block in a
    /// reader is worse than showing what the author wrote.
    case htmlBlock(String)

    /// Plain-text substitute used when a selection spanning this block is copied.
    public var copyText: String {
        switch self {
        case .table(let spec): return spec.tabSeparated
        case .math(let latex, _): return "$$\n\(latex)\n$$"
        case .diagram(let source, _): return "```mermaid\n\(source)\n```"
        case .frontmatter(let fm):
            let lines = fm.orderedKeys.compactMap { key -> String? in
                guard let value = fm.values[key] else { return nil }
                return "\(key): \(value.display)"
            }
            return (["---"] + lines + ["---"]).joined(separator: "\n")
        case .image(let source, let alt, _): return "![\(alt)](\(source))"
        case .htmlBlock(let html): return html
        }
    }
}

/// A parsed Markdown table, resolved to strings so the view is a pure layout concern.
public struct TableSpec {
    public struct Cell {
        public let text: NSAttributedString
        public init(text: NSAttributedString) { self.text = text }
    }

    public let header: [Cell]
    public let rows: [[Cell]]
    public let alignments: [NSTextAlignment]

    public init(header: [Cell], rows: [[Cell]], alignments: [NSTextAlignment]) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
    }

    public var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    public var tabSeparated: String {
        let head = header.map(\.text.string).joined(separator: "\t")
        let body = rows.map { $0.map(\.text.string).joined(separator: "\t") }
        return ([head] + body).joined(separator: "\n")
    }
}
