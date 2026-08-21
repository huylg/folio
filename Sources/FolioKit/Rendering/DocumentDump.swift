import AppKit

/// Deterministic textual dump of a parsed document, used as the primary regression check.
///
/// Cheaper than pixel diffing and free of pixel noise: it catches every structural and
/// index-alignment change, which is the class of bug that actually bites here. The PNG
/// snapshot exists for human eyeballing, not for diffing.
public enum DocumentDump {

    public static func dump(document: MarkdownDocument) -> String {
        var out: [String] = []

        out.append("FILE      \(document.url.lastPathComponent)")
        out.append("TITLE     \(document.title)")
        out.append("")

        out.append("STATS")
        out.append("  words        \(document.stats.words)")
        out.append("  readMinutes  \(document.stats.readMinutes)")
        out.append("  equations    \(document.stats.equations)")
        out.append("  codeBlocks   \(document.stats.codeBlocks)")
        out.append("  diagrams     \(document.stats.diagrams)")
        out.append("  citations    \(document.stats.citations)")
        out.append("  sections     \(document.stats.sectionCount)")
        out.append("")

        out.append("FRONTMATTER")
        if document.frontmatter.isEmpty {
            out.append("  (none)")
        } else {
            for key in document.frontmatter.orderedKeys {
                guard let value = document.frontmatter.values[key] else { continue }
                out.append("  \(pad(key, 14))\(value.display)")
            }
        }
        out.append("")

        // The index-alignment table. `outline` must be walkable by index from any consumer:
        // the sidebar highlight, the status bar's section counter, and the VoiceOver rotor
        // all index into it, and previously disagreed about what index 0 meant.
        out.append("OUTLINE  (\(document.outline.count) entries)")
        out.append("  idx  lvl  anchor                          title")
        for (index, entry) in document.outline.enumerated() {
            out.append("  \(pad(String(index), 5))\(pad(String(entry.level), 5))\(pad(entry.anchor, 32))\(entry.title)")
        }
        out.append("")

        let sections = document.outline.enumerated().filter { $0.element.level <= 2 }.map(\.offset)
        out.append("SECTIONS  outline indices with level <= 2: \(sections)")
        out.append("  count \(sections.count) (must equal stats.sections \(document.stats.sectionCount))")
        out.append("")

        // Block structure, so a change in what the builder emits shows up in the diff.
        let built = AttributedDocumentBuilder(
            document: document,
            metrics: DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                    lineWidth: .comfortable, density: .airy)
        ).build()

        out.append("BLOCKS  (\(built.blocks.count))")
        for block in built.blocks {
            out.append("  \(pad(describe(block.kind), 26))len \(block.range.length)")
        }
        out.append("")

        // Components are what the pane renders: one view each, one selection each. Dumping
        // them alongside the blocks is what catches a grouping mistake — a list that split into
        // one component per item, say — without rendering anything.
        out.append("COMPONENTS  (\(built.components.count))")
        for component in built.components {
            out.append("  \(pad(describe(component.kind), 26))\(describe(component.content))")
        }

        return out.joined(separator: "\n")
    }

    private static func describe(_ content: DocumentComponent.Content) -> String {
        switch content {
        case .text(let attributed):
            let paragraphs = attributed.string
                .components(separatedBy: "\n").filter { !$0.isEmpty }.count
            return "text(\(paragraphs) para, len \(attributed.length))"
        case .code(let label, let source, _):
            let lines = source.components(separatedBy: "\n").count
            return "code(\(label), \(lines) lines)"
        case .widget(let payload):
            return "widget(\(describe(payload)))"
        case .rule:
            return "rule"
        }
    }

    private static func describe(_ kind: BlockKind) -> String {
        switch kind {
        case .title: return "title"
        case .heading(let level): return "heading(\(level))"
        case .meta: return "meta"
        case .paragraph: return "paragraph"
        case .blockQuote(let depth): return "blockQuote(\(depth))"
        case .listItem(let depth, let isLast): return "listItem(\(depth)\(isLast ? ",last" : ""))"
        case .codeHeader: return "codeHeader"
        case .codeLine(let isFirst, let isLast):
            return "codeLine(\(isFirst ? "first" : "")\(isLast ? "last" : ""))"
        case .table: return "table"
        case .math: return "math"
        case .diagram: return "diagram"
        case .frontmatter: return "frontmatter"
        case .image: return "image"
        case .caption: return "caption"
        case .thematicBreak: return "thematicBreak"
        }
    }

    private static func describe(_ payload: BlockPayload) -> String {
        switch payload {
        case .table(let spec):
            return "table  \(spec.columnCount) columns, \(spec.rows.count) body rows, "
                + "header [\(spec.header.map(\.text.string).joined(separator: " | "))]"
        case .math(let latex, let number):
            return "math   equation \(number), \(latex.count) chars"
        case .diagram(let source):
            return "diagram \(source.components(separatedBy: "\n").count) lines"
        case .frontmatter(let fm):
            return "frontmatter \(fm.orderedKeys.count) keys"
        case .image(let source, let alt, _):
            return "image  \(source) alt=\(alt.isEmpty ? "(none)" : alt)"
        case .htmlBlock(let html):
            return "html   \(html.count) chars"
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }
}
