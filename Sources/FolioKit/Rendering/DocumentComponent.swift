import AppKit

/// One top-level piece of the document, rendered by one view.
///
/// The reading pane used to be a single `NSTextView` holding the whole document, with widgets
/// spliced in as attachments and cards painted by custom layout fragments. That bought
/// document-wide selection and `NSTextFinder` for free, and charged for it everywhere else:
/// widget sizing had to be pre-seeded through a cache because attachments are measured before
/// their views exist, card chrome had to be reverse-engineered out of paragraph spacing, and
/// every block-level interaction — hover, dimming, a widget that wants to lay itself out — had
/// to be smuggled past a text engine that owns the geometry.
///
/// A component owns its own view, its own geometry, and its own selection.
public struct DocumentComponent {

    public enum Content {
        /// Prose: a paragraph, heading, list, quote, or caption. Carries its own paragraph
        /// styles, so the spacing between the blocks *inside* it is already right.
        case text(NSAttributedString)
        /// A fenced code block: the header label, the source for the copy button, and the
        /// syntax-highlighted lines.
        case code(label: String, source: String, lines: NSAttributedString)
        /// A widget with a payload that can build and measure itself: table, equation,
        /// diagram, image, frontmatter, verbatim HTML.
        case widget(BlockPayload)
        /// A thematic break.
        case rule
    }

    /// The kind of the first block in the component, which is what its styling keys off.
    public let kind: BlockKind
    public let content: Content
    /// The component's character range in `BuiltDocument.attributed`.
    ///
    /// Everything that navigates by position — anchors, the outline probe, a restored scroll
    /// anchor — keeps working in character space, so those paths did not have to be rewritten
    /// on top of view geometry.
    public let range: NSRange

    public init(kind: BlockKind, content: Content, range: NSRange) {
        self.kind = kind
        self.content = content
        self.range = range
    }

    /// Plain text for the clipboard.
    public var copyText: String {
        switch content {
        case .text(let attributed): return attributed.string
        case .code(let label, let source, _): return "```\(label)\n\(source)\n```"
        case .widget(let payload): return payload.copyText
        case .rule: return "---"
        }
    }
}

/// Groups a built document's block records into components.
///
/// The grouping is the whole point: a list is one component rather than one per item, a quote
/// is one component however many paragraphs it holds, and a fenced code block is one component
/// rather than a header plus a paragraph per line. Selection, which is per-component, then
/// covers the units a reader actually thinks in.
public enum ComponentSplitter {

    public static func components(
        in attributed: NSAttributedString,
        blocks: [BlockRecord]
    ) -> [DocumentComponent] {
        var components: [DocumentComponent] = []
        var index = 0

        while index < blocks.count {
            let block = blocks[index]

            switch block.kind {
            case .codeHeader:
                // The header carries the label and the full source as attributes; the lines
                // that follow carry the highlighting.
                let end = runEnd(from: index + 1, in: blocks) { kind in
                    if case .codeLine = kind { return true } else { return false }
                }
                let range = union(blocks[index], through: blocks[end - 1])
                let label = attributed.attribute(.folioCodeLabel, at: block.range.location,
                                                 effectiveRange: nil) as? String ?? "code"
                let source = attributed.attribute(.folioCodeSource, at: block.range.location,
                                                  effectiveRange: nil) as? String ?? ""
                let linesRange = union(blocks[index + 1], through: blocks[end - 1])
                components.append(DocumentComponent(
                    kind: .codeHeader,
                    content: .code(label: label, source: source,
                                   lines: attributed.attributedSubstring(from: linesRange)),
                    range: range
                ))
                index = end

            case .listItem:
                let end = runEnd(from: index, in: blocks) { kind in
                    if case .listItem = kind { return true } else { return false }
                }
                components.append(text(from: attributed, blocks: blocks,
                                      first: index, end: end))
                index = end

            case .blockQuote:
                let end = runEnd(from: index, in: blocks) { kind in
                    if case .blockQuote = kind { return true } else { return false }
                }
                components.append(text(from: attributed, blocks: blocks,
                                       first: index, end: end))
                index = end

            case .thematicBreak:
                components.append(DocumentComponent(kind: block.kind, content: .rule,
                                                    range: block.range))
                index += 1

            case .table, .math, .diagram, .frontmatter, .image:
                // The payload rides on the attachment the builder spliced in.
                if let attachment = attributed.attribute(
                    .attachment, at: block.range.location, effectiveRange: nil
                ) as? BlockPayloadCarrying {
                    components.append(DocumentComponent(kind: block.kind,
                                                        content: .widget(attachment.payload),
                                                        range: block.range))
                }
                index += 1

            case .codeLine:
                // Only reachable if a code card lost its header, which the builder never emits.
                components.append(text(from: attributed, blocks: blocks,
                                       first: index, end: index + 1))
                index += 1

            case .title, .heading, .meta, .paragraph, .caption:
                components.append(text(from: attributed, blocks: blocks,
                                       first: index, end: index + 1))
                index += 1
            }
        }
        return components
    }

    /// One text component spanning `blocks[first ..< end]`, newlines between them included so
    /// each block stays its own paragraph.
    private static func text(
        from attributed: NSAttributedString,
        blocks: [BlockRecord],
        first: Int,
        end: Int
    ) -> DocumentComponent {
        let range = union(blocks[first], through: blocks[end - 1])
        return DocumentComponent(
            kind: blocks[first].kind,
            content: .text(attributed.attributedSubstring(from: range)),
            range: range
        )
    }

    /// The index just past a run of blocks whose kinds all satisfy `matches`.
    private static func runEnd(
        from start: Int,
        in blocks: [BlockRecord],
        matches: (BlockKind) -> Bool
    ) -> Int {
        var end = start
        while end < blocks.count, matches(blocks[end].kind) { end += 1 }
        return max(end, start + 1)
    }

    private static func union(_ first: BlockRecord, through last: BlockRecord) -> NSRange {
        NSRange(location: first.range.location,
                length: max(0, NSMaxRange(last.range) - first.range.location))
    }
}

/// Lets the splitter read a payload off whatever the builder used to carry it, without the
/// attachment type being visible to it.
public protocol BlockPayloadCarrying {
    var payload: BlockPayload { get }
}
