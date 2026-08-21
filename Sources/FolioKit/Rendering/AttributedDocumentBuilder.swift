import AppKit
import Markdown

/// Turns a parsed Markdown document into an `NSAttributedString` plus navigation indices.
///
/// Replaces the HTML emitter. Split into two walkers rather than one `MarkupVisitor`, because
/// the two halves want opposite shapes: block nodes need the output length before and after
/// each block in order to record ranges, while inline nodes want composable return values and
/// an inherited trait stack.
public struct AttributedDocumentBuilder {

    public let document: MarkdownDocument
    public let metrics: DocumentMetrics
    /// How far prose is inset inside the wider block container.
    public let proseInset: CGFloat
    private let settings: AppSettings

    public init(document: MarkdownDocument,
                metrics: DocumentMetrics,
                proseInset: CGFloat = 0,
                settings: AppSettings = .shared) {
        self.document = document
        self.metrics = metrics
        self.proseInset = proseInset
        self.settings = settings
    }

    public func build() -> BuiltDocument {
        var walker = BlockWalker(
            metrics: metrics,
            proseInset: proseInset,
            outline: document.outline,
            baseURL: document.url.deletingLastPathComponent(),
            settings: settings
        )

        if settings.showFrontmatter, !document.frontmatter.isEmpty {
            walker.appendBlockWidget(BlockPayload.frontmatter(document.frontmatter), kind: BlockKind.frontmatter)
        }

        // Mirrors the previous renderer's title handling: a document that already opens with
        // an h1 uses it and gets the meta line just after; otherwise a title is synthesized
        // from frontmatter or the filename.
        //
        // The synthesized title is NOT recorded as a heading, which is what keeps
        // `headings` index-aligned with `outline`.
        let opensWithH1 = (document.markup.child(at: 0) as? Heading)?.level == 1
        if opensWithH1 {
            walker.pendingMetaLine = metaLine()
        } else {
            walker.appendSyntheticTitle(document.title)
            walker.appendMetaLine(metaLine())
        }

        walker.visit(document.markup)
        walker.finish()

        return BuiltDocument(
            attributed: walker.out,
            anchors: walker.anchors,
            headings: walker.headings,
            sectionIndices: walker.headings.enumerated()
                .filter { $0.element.level <= 2 }.map { $0.offset },
            blocks: walker.blocks,
            components: ComponentSplitter.components(in: walker.out, blocks: walker.blocks)
        )
    }

    private func metaLine() -> String {
        var parts: [String] = []
        if let date = document.modificationDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("Last edited " + formatter.localizedString(for: date, relativeTo: Date()))
        }
        let words = NumberFormatter.localizedString(
            from: NSNumber(value: document.stats.words), number: .decimal
        )
        parts.append("\(words) words")
        parts.append("\(document.stats.readMinutes) min read")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Block walker

struct BlockWalker: MarkupWalker {
    let metrics: DocumentMetrics
    let proseInset: CGFloat
    let outline: [OutlineEntry]
    let baseURL: URL
    let settings: AppSettings

    var out = NSMutableAttributedString()
    var anchors: [String: NSRange] = [:]
    var headings: [HeadingRange] = []
    var blocks: [BlockRecord] = []
    var pendingMetaLine: String?

    /// Consumed positionally as headings are encountered, exactly as the HTML emitter consumed
    /// its anchor list — the walkers visit headings in the same order `AnalysisWalker` did.
    private var outlineCursor = 0
    private var equationNumber = 0
    private var listDepth = 0
    private var quoteDepth = 0

    init(metrics: DocumentMetrics, proseInset: CGFloat, outline: [OutlineEntry],
         baseURL: URL, settings: AppSettings) {
        self.metrics = metrics
        self.proseInset = proseInset
        self.outline = outline
        self.baseURL = baseURL
        self.settings = settings
    }

    // MARK: Emitting

    /// Appends one paragraph and records its range as a block.
    private mutating func appendParagraph(
        _ content: NSAttributedString,
        kind: BlockKind,
        extraAttributes: [NSAttributedString.Key: Any] = [:],
        overridingStyle: NSParagraphStyle? = nil
    ) {
        let start = out.length
        let piece = NSMutableAttributedString(attributedString: content)
        let full = NSRange(location: 0, length: piece.length)
        piece.addAttribute(
            .paragraphStyle,
            value: overridingStyle ?? metrics.paragraphStyle(for: kind, proseInset: proseInset),
            range: full
        )
        piece.addAttribute(.folioBlockKind, value: kind, range: full)
        for (key, value) in extraAttributes { piece.addAttribute(key, value: value, range: full) }
        out.append(piece)
        blocks.append(BlockRecord(range: NSRange(location: start, length: piece.length), kind: kind))
        newline()
    }

    private mutating func newline() {
        // The separator inherits the preceding paragraph's style so its spacing applies.
        var attributes: [NSAttributedString.Key: Any] = [:]
        if out.length > 0 {
            attributes = out.attributes(at: out.length - 1, effectiveRange: nil)
            attributes.removeValue(forKey: .folioCopyText)
            attributes.removeValue(forKey: .attachment)
        }
        out.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    private func inline(_ markup: Markup, base: InlineRole = .body) -> NSAttributedString {
        var visitor = InlineVisitor(metrics: metrics, baseRole: base, baseURL: baseURL)
        return visitor.visit(markup)
    }

    mutating func finish() {
        // Trim the trailing separator so the document doesn't end on an empty line.
        if out.length > 0, out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
    }

    // MARK: Title, meta, widgets

    mutating func appendSyntheticTitle(_ title: String) {
        let attributed = NSAttributedString(
            string: title,
            attributes: metrics.attributes(for: .heading(1))
        )
        appendParagraph(attributed, kind: .title)
    }

    mutating func appendMetaLine(_ text: String) {
        guard !text.isEmpty else { return }
        appendParagraph(
            NSAttributedString(string: text, attributes: metrics.attributes(for: .meta)),
            kind: .meta
        )
    }

    /// Splices a block widget in as a single attachment character.
    ///
    /// The character is a placeholder in the document's text, not a hosting point for a view:
    /// the component that renders this block is built from the payload by
    /// `ComponentSplitter`.
    mutating func appendBlockWidget(_ payload: BlockPayload, kind: BlockKind) {
        let attachment = BlockPayloadAttachment(payload: payload)
        let piece = NSMutableAttributedString(attachment: attachment)
        let full = NSRange(location: 0, length: piece.length)
        piece.addAttribute(.font, value: metrics.ramp.body(), range: full)
        piece.addAttribute(.folioCopyText, value: payload.copyText, range: full)
        appendParagraph(piece, kind: kind)
    }

    // MARK: MarkupWalker

    mutating func visitHeading(_ heading: Heading) {
        let text = inline(heading, base: .heading(heading.level))

        // Positional consumption keeps the outline mapping exact even when two headings share
        // a title (the outline's slugs are already de-duplicated with -2, -3 suffixes).
        var anchor: String?
        var outlineIndex: Int?
        if outlineCursor < outline.count {
            anchor = outline[outlineCursor].anchor
            outlineIndex = outlineCursor
            outlineCursor += 1
        }

        let start = out.length
        var extra: [NSAttributedString.Key: Any] = [:]
        if let anchor { extra[.folioAnchor] = anchor }
        if let outlineIndex { extra[.folioHeadingIndex] = outlineIndex }

        appendParagraph(text, kind: .heading(heading.level), extraAttributes: extra)
        let range = NSRange(location: start, length: text.length)

        if let anchor { anchors[anchor] = range }
        if let outlineIndex {
            headings.append(HeadingRange(outlineIndex: outlineIndex,
                                         level: heading.level,
                                         range: range))
        }

        // A real leading h1 gets the meta line immediately after it.
        if heading.level == 1, let meta = pendingMetaLine {
            pendingMetaLine = nil
            appendMetaLine(meta)
        }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        // A paragraph whose only child is an image becomes a figure: the widget, then a real
        // caption paragraph. Keeping the caption as text rather than inside the view means it
        // is selectable and findable, which the old `<figcaption>` was not.
        if paragraph.childCount == 1, let image = paragraph.child(at: 0) as? Markdown.Image {
            appendBlockWidget(
                BlockPayload.image(source: image.source ?? "", alt: image.plainText, base: baseURL),
                kind: .image
            )
            let alt = image.plainText
            if !alt.isEmpty {
                appendParagraph(
                    NSAttributedString(string: alt, attributes: metrics.attributes(for: .caption)),
                    kind: .caption
                )
            }
            return
        }

        if quoteDepth > 0 {
            appendParagraph(inline(paragraph), kind: .blockQuote(depth: quoteDepth))
        } else {
            appendParagraph(inline(paragraph), kind: .paragraph)
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        quoteDepth += 1
        descendInto(blockQuote)
        quoteDepth -= 1
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        // A single space carries the paragraph; the rule itself is drawn by a layout fragment.
        appendParagraph(
            NSAttributedString(string: " ", attributes: [.font: metrics.ramp.caption()]),
            kind: .thematicBreak
        )
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        visitList(list, ordered: false, start: 1)
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        visitList(list, ordered: true, start: Int(list.startIndex))
    }

    private mutating func visitList(_ list: Markup, ordered: Bool, start: Int) {
        listDepth += 1
        defer { listDepth -= 1 }

        let items = Array(list.children.compactMap { $0 as? ListItem })
        let textList = NSTextList(markerFormat: Self.markerFormat(ordered: ordered, depth: listDepth),
                                  options: 0)
        if ordered { textList.startingItemNumber = start }

        for (offset, item) in items.enumerated() {
            let isLast = offset == items.count - 1 && listDepth == 1
            appendListItem(item, textList: textList, ordinal: start + offset,
                           ordered: ordered, isLast: isLast)
        }
    }

    private mutating func appendListItem(
        _ item: ListItem,
        textList: NSTextList,
        ordinal: Int,
        ordered: Bool,
        isLast: Bool
    ) {
        let kind = BlockKind.listItem(depth: listDepth, isLast: isLast)
        let style = metrics.paragraphStyle(for: kind, proseInset: proseInset)
            .mutableCopy() as! NSMutableParagraphStyle

        let marker = NSMutableAttributedString()
        if let checkbox = item.checkbox {
            // Task items drop the list marker entirely, matching the previous `list-style: none`.
            let checked = checkbox == .checked
            marker.append(checkboxAttachment(checked: checked))
            marker.append(NSAttributedString(
                string: "\t",
                attributes: [.font: metrics.ramp.body(),
                             .folioCopyText: checked ? "[x] " : "[ ] "]
            ))
        } else {
            // `style.textLists` is deliberately NOT set: TextKit renders a marker from it in
            // addition to the one written into the string, so every bullet appeared twice.
            let glyph = ordered ? textList.marker(forItemNumber: ordinal) : textList.marker(forItemNumber: 1)
            var attributes = metrics.attributes(for: .marker)
            attributes[.folioCopyText] = ordered ? "\(ordinal). " : "- "
            marker.append(NSAttributedString(string: glyph + "\t", attributes: attributes))
        }

        // The item's first paragraph joins the marker line; later blocks become their own
        // paragraphs at the same indent.
        var isFirstChild = true
        for child in item.children {
            if let paragraph = child as? Paragraph, isFirstChild {
                let line = NSMutableAttributedString(attributedString: marker)
                line.append(inline(paragraph))
                let start = out.length
                let full = NSRange(location: 0, length: line.length)
                line.addAttribute(.paragraphStyle, value: style, range: full)
                line.addAttribute(.folioBlockKind, value: kind, range: full)
                out.append(line)
                blocks.append(BlockRecord(
                    range: NSRange(location: start, length: line.length), kind: kind
                ))
                newline()
                isFirstChild = false
            } else {
                visit(child)
                isFirstChild = false
            }
        }
    }

    private func checkboxAttachment(checked: Bool) -> NSAttributedString {
        let name = checked ? "checkmark.square.fill" : "square"
        let configuration = NSImage.SymbolConfiguration(
            pointSize: metrics.ramp.body().pointSize, weight: .regular
        )
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: checked ? "Checked" : "Unchecked")?
            .withSymbolConfiguration(configuration) {
            image.isTemplate = true
            attachment.image = image
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(
            [.foregroundColor: checked ? Ink.accent : Ink.faint,
             .font: metrics.ramp.body()],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func markerFormat(ordered: Bool, depth: Int) -> NSTextList.MarkerFormat {
        if ordered {
            switch depth {
            case 1: return .decimal
            case 2: return .lowercaseAlpha
            default: return .lowercaseRoman
            }
        }
        switch depth {
        case 1: return .disc
        case 2: return .circle
        default: return .square
        }
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let info = CodeBlockInfo(infoString: codeBlock.language)
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }

        switch info.role {
        case .math:
            equationNumber += 1
            guard settings.renderEquations else {
                appendCodeCard(code, label: "latex", language: nil)
                return
            }
            appendBlockWidget(BlockPayload.math(latex: code, number: equationNumber), kind: .math)

        case .diagram:
            guard settings.renderDiagrams else {
                appendCodeCard(code, label: "mermaid", language: nil)
                return
            }
            appendBlockWidget(BlockPayload.diagram(source: code), kind: .diagram)

        case .code:
            appendCodeCard(code, label: info.label, language: info.language)
        }
    }

    /// Code is emitted as real text, not an attachment view, so ⌘F finds it, a few lines can
    /// be selected out of a block, and VoiceOver reads it line by line. The card's fill,
    /// border, and header bar are drawn behind the text by `CodeCardLayoutFragment`.
    private mutating func appendCodeCard(_ code: String, label: String, language: String?) {
        // The header is its own paragraph, carrying the label and the source: that is where
        // `ComponentSplitter` reads them to build the card.
        appendParagraph(
            NSAttributedString(string: label, attributes: [
                .font: TypeRamp.fixedPitchMono(ofSize: metrics.ramp.caption().pointSize),
                .foregroundColor: Ink.tertiary,
            ]),
            kind: .codeHeader,
            extraAttributes: [.folioCodeSource: code, .folioCodeLabel: label]
        )

        let lines = code.components(separatedBy: "\n")
        let tokens = SyntaxHighlighter.tokenize(code, language: language)

        for (index, line) in lines.enumerated() {
            let kind = BlockKind.codeLine(isFirst: index == 0, isLast: index == lines.count - 1)
            let piece = NSMutableAttributedString(
                string: line.isEmpty ? " " : line,
                attributes: [
                    .font: metrics.ramp.mono(),
                    .foregroundColor: Ink.body,
                ]
            )
            if !line.isEmpty {
                for token in tokens[index] {
                    piece.addAttributes(
                        [.foregroundColor: Ink.syntax(token.kind),
                         .folioInlineRole: InlineRole.syntax(token.kind)],
                        range: NSRange(token.range, in: line)
                    )
                }
            }
            // The line's own indentation drives its hanging indent, so a wrapped continuation
            // aligns past the code it belongs to.
            let style = metrics.codeLineStyle(leadingColumns: Self.leadingColumns(of: line))
            appendParagraph(piece, kind: kind,
                            extraAttributes: index == 0 ? [.folioCodeSource: code] : [:],
                            overridingStyle: style)
        }
    }

    mutating func visitTable(_ table: Markdown.Table) {
        let alignments = table.columnAlignments.map { alignment -> NSTextAlignment in
            switch alignment {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            case nil: return .natural
            }
        }
        let header: [TableSpec.Cell] = table.head.cells.map {
            TableSpec.Cell(text: inline($0, base: .caption))
        }
        let rows: [[TableSpec.Cell]] = table.body.rows.map { row in
            row.cells.map { TableSpec.Cell(text: inline($0)) }
        }
        appendBlockWidget(
            BlockPayload.table(TableSpec(header: header, rows: rows, alignments: alignments)),
            kind: .table
        )
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        var raw = html.rawHTML
        while raw.hasSuffix("\n") { raw.removeLast() }
        // A comment is not content. `<!-- PDF page 9 -->` is a note to the author or a marker
        // left by a conversion tool, invisible in every other renderer — and showing it in a
        // source card was worse than dropping the block, because it put a card in the reading
        // flow for text that is not meant to be read. A block that also holds real markup keeps
        // its card, comments and all: the card's promise is that it shows what the author wrote.
        guard !Self.holdsOnlyComments(raw) else { return }
        appendCodeCard(raw, label: "html", language: nil)
    }
}

extension BlockWalker {

    /// Whether an HTML block is nothing but comments and whitespace.
    static func holdsOnlyComments(_ raw: String) -> Bool {
        stripComments(raw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The block with every `<!-- … -->` span removed. An unterminated comment swallows the
    /// rest, which is what a parser does with it too.
    static func stripComments(_ raw: String) -> String {
        var out = ""
        var rest = Substring(raw)
        while let open = rest.range(of: "<!--") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else {
                return out
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// Indentation of a source line in monospace columns, counting a tab as four.
    static func leadingColumns(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 }
            else if character == "\t" { columns += 4 }
            else { break }
        }
        return columns
    }
}

// MARK: - Code fence info string

/// Parses a fence info string, preserving the previous renderer's accepted forms:
/// `python`, `python:router.py`, `python router.py`, `python title="router.py"`.
struct CodeBlockInfo {
    enum Role { case code, math, diagram }

    let language: String?
    let filename: String?
    let role: Role

    init(infoString: String?) {
        let info = (infoString ?? "").trimmingCharacters(in: .whitespaces)
        let tokens = info.split(separator: " ").map(String.init)

        var language: String?
        var filename: String?

        if let first = tokens.first {
            if first.contains(":") {
                let parts = first.split(separator: ":", maxSplits: 1)
                language = String(parts[0])
                if parts.count > 1 { filename = String(parts[1]) }
            } else {
                language = first
            }
        }
        for token in tokens.dropFirst() {
            if token.hasPrefix("title=") {
                filename = String(token.dropFirst(6))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if token.contains("."), filename == nil {
                filename = token
            }
        }

        self.language = language?.isEmpty == false ? language : nil
        self.filename = filename

        switch language?.lowercased() {
        case "math", "latex", "tex": role = .math
        case "mermaid": role = .diagram
        default: role = .code
        }
    }

    var label: String {
        filename ?? language ?? "code"
    }
}

extension NSAttributedString.Key {
    /// Header label for a code card, stamped on its first line.
    public static let folioCodeLabel = NSAttributedString.Key("folioCodeLabel")
    /// Full source of a code card, stamped on its first line so the copy button owns its own
    /// text rather than indexing into a shared array.
    public static let folioCodeSource = NSAttributedString.Key("folioCodeSource")
}
