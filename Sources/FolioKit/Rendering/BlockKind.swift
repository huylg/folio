import AppKit

/// The structural role of a top-level block, carried as an attribute on every paragraph.
///
/// Attaching semantics to runs rather than baking in final attributes is what makes
/// restyling a pure function `(role, metrics) → attributes`: a text-size or density change
/// re-derives attributes without re-parsing the document.
public enum BlockKind: Equatable, Hashable {
    /// The document title — either a real leading h1 or a synthesized one.
    case title
    case heading(Int)
    /// The "Last edited · N words · N min read" line under the title.
    case meta
    case paragraph
    case blockQuote(depth: Int)
    case listItem(depth: Int, isLast: Bool)
    /// The header strip of a code card, carrying the language or filename label. A real
    /// paragraph rather than decoration extending out of the first code line, so the card's
    /// chrome never paints over whatever precedes the block.
    case codeHeader
    /// One line of a fenced code block. Code is real text, not an attachment, so ⌘F can
    /// find it and VoiceOver can read it line by line.
    case codeLine(isFirst: Bool, isLast: Bool)
    case table
    case math
    case diagram
    case frontmatter
    case image
    case caption
    case thematicBreak

    /// Blocks that take the container's full width rather than the narrower prose measure:
    /// code, tables, diagrams, equations, and the frontmatter card are not prose.
    public var usesFullBlockWidth: Bool {
        switch self {
        case .codeHeader, .codeLine, .table, .math, .diagram, .frontmatter, .image:
            return true
        default:
            return false
        }
    }

    public var isHeading: Bool {
        switch self {
        case .title, .heading: return true
        default: return false
        }
    }

    /// Heading level for the accessibility rotor and outline mapping; `nil` for body blocks.
    public var headingLevel: Int? {
        switch self {
        case .title: return 1
        case .heading(let level): return level
        default: return nil
        }
    }
}

/// The semantic role of an inline run.
public enum InlineRole: Equatable, Hashable {
    case body
    case strong
    case emphasis
    case code
    case link
    /// A list bullet or number, so it can be styled and copy-substituted independently.
    case marker
    case caption
    case meta
    case heading(Int)
    case syntax(SyntaxHighlighter.TokenClass)
    case superscript
    case subscriptRole
}

/// Padding inside a code card, in points at the document's current scale.
public struct CodeCardInsets: Equatable, Hashable {
    /// Above the header label, and again below it down to the divider. The header strip is a
    /// drawn band in `CodeComponentView`, so this is only the label's breathing room.
    public let header: CGFloat
    /// Between the divider and the first code line.
    public let bodyTop: CGFloat
    /// Under the last code line.
    ///
    /// Deliberately larger than `bodyTop`. Both are measured to the text's line *box*, and the
    /// last line's descender room sits inside its own box — so an equal padding puts the card's
    /// edge a descender closer to the ink at the bottom than at the top, and the card reads as
    /// bottom-cropped. Adding the descender back evens out the ink-to-edge gap.
    public let bodyBottom: CGFloat

    public init(header: CGFloat, bodyTop: CGFloat, bodyBottom: CGFloat) {
        self.header = header
        self.bodyTop = bodyTop
        self.bodyBottom = bodyBottom
    }
}

extension NSAttributedString.Key {
    /// `BlockKind` for the paragraph.
    public static let folioBlockKind = NSAttributedString.Key("folioBlockKind")
    /// `InlineRole` for the run.
    public static let folioInlineRole = NSAttributedString.Key("folioInlineRole")
    /// Slug of the heading this range belongs to, matching `OutlineEntry.anchor`.
    public static let folioAnchor = NSAttributedString.Key("folioAnchor")
    /// Index into `MarkdownDocument.outline`, for outline highlighting and the rotor.
    public static let folioHeadingIndex = NSAttributedString.Key("folioHeadingIndex")
    /// Plain-text substitute used when copying a selection that spans an attachment.
    public static let folioCopyText = NSAttributedString.Key("folioCopyText")
    /// Marks an inline-code sub-range, for the rounded-pill layout fragment.
    public static let folioInlineCode = NSAttributedString.Key("folioInlineCode")
}

/// A top-level block's character range, used by focus mode and the code-card fragment.
public struct BlockRecord: Equatable {
    public let range: NSRange
    public let kind: BlockKind

    public init(range: NSRange, kind: BlockKind) {
        self.range = range
        self.kind = kind
    }
}

/// A heading's character range, index-aligned with `MarkdownDocument.outline`.
///
/// The synthesized title heading is deliberately excluded from the collection of these, which
/// is what keeps `outlineIndex` a valid index into `outline` for every entry — the two
/// off-by-one bugs in the previous JavaScript scroll-spy both came from counting a heading
/// that the outline did not contain, or from omitting levels the outline did contain.
public struct HeadingRange: Equatable {
    public let outlineIndex: Int
    public let level: Int
    public let range: NSRange

    public init(outlineIndex: Int, level: Int, range: NSRange) {
        self.outlineIndex = outlineIndex
        self.level = level
        self.range = range
    }
}
