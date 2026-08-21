import AppKit

/// Fonts, spacing, and the reading measure — everything geometric about the document,
/// derived from the current settings. Recomputed only when a setting that affects it changes.
public struct DocumentMetrics: Equatable {
    public let ramp: TypeRamp
    public let lineWidth: AppSettings.LineWidth
    public let density: AppSettings.Density

    /// Minimum horizontal padding retained when the pane is narrower than the measure.
    public static let minimumPadding: CGFloat = 24

    /// How much wider than the prose column a block may be.
    ///
    /// One column: prose and blocks are the same width and share a left edge. Letting blocks
    /// bleed wider — 1.35, which gave the code area about 76 monospace columns instead of 56 —
    /// bought code room at the cost of two competing left margins, a card or code block
    /// starting well left of the title and paragraphs above it. The single edge wins; a
    /// wrapped code line still hangs past its own indentation, which is what keeps it readable
    /// (`codeLineStyle`). Raising this again reinstates the bleed, and `proseInset` re-centres
    /// prose inside it, with no other change.
    public static let blockWidthScale: CGFloat = 1
    /// Top inset for the text container.
    public static let topPadding: CGFloat = 44
    public static let bottomPadding: CGFloat = 80

    public init(ramp: TypeRamp, lineWidth: AppSettings.LineWidth, density: AppSettings.Density) {
        self.ramp = ramp
        self.lineWidth = lineWidth
        self.density = density
    }

    public init(settings: AppSettings = .shared, presentationScale: CGFloat = 1) {
        self.init(
            ramp: TypeRamp(family: settings.readingFont,
                           textSize: settings.textSize,
                           presentationScale: presentationScale),
            lineWidth: settings.lineWidth,
            density: settings.density
        )
    }

    // MARK: Measure

    /// The reading column width, in points, derived from a character count.
    ///
    /// Apple publishes no line-length guidance for macOS (`readableContentGuide` is UIKit
    /// only), so the 62/72/84 band is typographic convention rather than a platform rule.
    /// Expressing it in characters rather than pixels is what lets the column grow with ⌘+
    /// and with presentation mode — a fixed pixel width cannot.
    public var measure: CGFloat {
        (CGFloat(lineWidth.characters) * ramp.averageCharacterWidth()).rounded()
    }

    /// Measure clamped to what the pane can actually show.
    public func measure(fitting paneWidth: CGFloat) -> CGFloat {
        let available = paneWidth - 2 * Self.minimumPadding
        return max(1, min(measure, available))
    }

    /// Width available to blocks: the text container is sized to this, and prose is inset
    /// within it.
    public func blockMeasure(fitting paneWidth: CGFloat) -> CGFloat {
        let available = paneWidth - 2 * Self.minimumPadding
        return max(1, min((measure * Self.blockWidthScale).rounded(), available))
    }

    /// How far prose is indented inside the container so it keeps its own narrower measure.
    public func proseInset(fitting paneWidth: CGFloat) -> CGFloat {
        max(0, ((blockMeasure(fitting: paneWidth) - measure) / 2).rounded())
    }

    /// Horizontal inset that centers the container in the pane.
    public func horizontalInset(forPaneWidth paneWidth: CGFloat) -> CGFloat {
        let used = blockMeasure(fitting: paneWidth)
        return max(Self.minimumPadding, ((paneWidth - used) / 2).rounded())
    }

    // MARK: Inline attributes

    /// Attributes for an inline role. Together with `paragraphStyle(for:)` this is the whole
    /// restyle path: enumerate roles, re-apply, done — no re-parse.
    public func attributes(for role: InlineRole) -> [NSAttributedString.Key: Any] {
        switch role {
        case .body:
            return [.font: ramp.body(), .foregroundColor: Ink.body]

        case .strong:
            return [.font: weighted(ramp.body(), .semibold), .foregroundColor: Ink.heading]

        case .emphasis:
            return italic(ramp.body())

        case .code:
            return [
                .font: ramp.inlineCode(),
                .foregroundColor: Ink.body,
                .backgroundColor: Ink.cardFillStrong,
                .folioInlineCode: true,
            ]

        case .link:
            return [
                .font: ramp.body(),
                .foregroundColor: Ink.link,
                .underlineStyle: 0,
                .cursor: NSCursor.pointingHand,
            ]

        case .marker:
            return [.font: ramp.body(), .foregroundColor: Ink.tertiary]

        case .caption:
            return [.font: ramp.caption(), .foregroundColor: Ink.tertiary]

        case .meta:
            return [.font: ramp.caption(), .foregroundColor: Ink.tertiary]

        case .heading(let level):
            return [.font: ramp.heading(level: level), .foregroundColor: Ink.heading]

        case .syntax(let token):
            return [.font: ramp.mono(), .foregroundColor: Ink.syntax(token)]

        case .superscript:
            return [
                .font: scaled(ramp.body(), 0.68),
                .foregroundColor: Ink.accent,
                .baselineOffset: (ramp.body().pointSize * 0.33).rounded(),
            ]

        case .subscriptRole:
            return [
                .font: scaled(ramp.body(), 0.68),
                .foregroundColor: Ink.body,
                .baselineOffset: -(ramp.body().pointSize * 0.2).rounded(),
            ]
        }
    }

    // MARK: Paragraph styles

    /// AppKit **adds** `previous.paragraphSpacing` and `next.paragraphSpacingBefore` — it does
    /// not collapse them, which is the classic source of doubled gaps. So `paragraphSpacing`
    /// carries the whole inter-block gap for prose, and `paragraphSpacingBefore` carries only
    /// the extra a heading needs above whatever preceded it.
    public func paragraphStyle(for kind: BlockKind, proseInset: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // `.natural` on both gives the HIG's per-paragraph RTL resolution for free: a
        // three-line Arabic paragraph aligns right while its Latin neighbours stay left.
        // Never set `.left`.
        style.alignment = .natural
        style.baseWritingDirection = .natural

        let s = ramp.scale
        func pt(_ value: CGFloat) -> CGFloat { (value * s).rounded() }

        // Prose keeps its narrower measure by sitting inside the wider container; blocks use the
        // full width and take no inset.
        let inset = kind.usesFullBlockWidth ? 0 : proseInset

        switch kind {
        case .title:
            pin(style, ramp.leading(forHeadingLevel: 1), font: ramp.heading(level: 1))
            style.paragraphSpacing = pt(14)
            style.lineBreakStrategy = .pushOut

        case .heading(let level):
            pin(style, ramp.leading(forHeadingLevel: level), font: ramp.heading(level: level))
            switch level {
            case 1:
                style.paragraphSpacingBefore = pt(18)
                style.paragraphSpacing = pt(14)
            case 2:
                style.paragraphSpacingBefore = pt(14)
                style.paragraphSpacing = pt(8)
            case 3:
                style.paragraphSpacingBefore = pt(12)
                style.paragraphSpacing = pt(6)
            case 4:
                style.paragraphSpacingBefore = pt(12)
                style.paragraphSpacing = pt(5)
            default:
                style.paragraphSpacingBefore = pt(11)
                style.paragraphSpacing = pt(4)
            }
            style.lineBreakStrategy = .pushOut

        case .meta:
            style.lineHeightMultiple = 1.3
            style.paragraphSpacing = pt(32)

        case .paragraph:
            style.lineHeightMultiple = density.lineHeightMultiple
            style.paragraphSpacing = pt(14)

        case .blockQuote(let depth):
            style.lineHeightMultiple = density.lineHeightMultiple
            style.paragraphSpacingBefore = pt(8)
            style.paragraphSpacing = pt(14)
            let indent = pt(18 * CGFloat(max(1, depth)))
            style.firstLineHeadIndent = indent
            style.headIndent = indent

        case .listItem(let depth, let isLast):
            style.lineHeightMultiple = density.lineHeightMultiple
            style.paragraphSpacing = isLast ? pt(14) : pt(5)
            let base = pt(20 * CGFloat(max(0, depth - 1)))
            let hang = base + pt(20)
            style.firstLineHeadIndent = base
            style.headIndent = hang
            style.tabStops = [NSTextTab(textAlignment: .left, location: hang)]
            style.defaultTabInterval = pt(20)

        case .codeHeader:
            // The header is a label inside `CodeComponentView`; this style only shapes the
            // header line in the document's text, which is what the dump and the clipboard see.
            style.firstLineHeadIndent = pt(CardChrome.codeGutter)
            style.headIndent = pt(CardChrome.codeGutter)
            style.tailIndent = -pt(CardChrome.codeGutter)

        case .codeLine:
            return codeLineStyle(leadingColumns: 0)

        case .table, .math, .diagram:
            // No pinned height: a maximumLineHeight would clip the attachment view.
            style.paragraphSpacingBefore = pt(6)
            style.paragraphSpacing = pt(18)

        case .frontmatter:
            style.paragraphSpacing = pt(34)

        case .image:
            style.paragraphSpacingBefore = pt(6)
            style.paragraphSpacing = pt(8)

        case .caption:
            style.lineHeightMultiple = 1.3
            style.paragraphSpacingBefore = pt(4)
            style.paragraphSpacing = pt(20)

        case .thematicBreak:
            style.minimumLineHeight = 1
            style.maximumLineHeight = 1
            style.paragraphSpacingBefore = pt(26)
            style.paragraphSpacing = pt(26)

        }

        if inset > 0 {
            style.firstLineHeadIndent += inset
            style.headIndent += inset
            style.tailIndent = style.tailIndent == 0 ? -inset : style.tailIndent - inset
            style.tabStops = style.tabStops.map {
                NSTextTab(textAlignment: $0.alignment, location: $0.location + inset,
                          options: $0.options)
            }
        }
        return style
    }

    /// The gap a non-prose component needs above and below it.
    ///
    /// Prose carries its spacing in its own paragraph styles — that is what lets a list item sit
    /// closer to the next item than a paragraph does to the next paragraph, inside one component.
    /// A card has no paragraph to hang a gap on, so the stack adds it from here, with the same
    /// numbers the attachment paragraph used to carry.
    public func componentSpacing(for kind: BlockKind) -> (before: CGFloat, after: CGFloat) {
        func pt(_ value: CGFloat) -> CGFloat { (value * ramp.scale).rounded() }
        switch kind {
        case .codeHeader, .codeLine:
            return (pt(10), pt(8))
        case .table, .math, .diagram:
            return (pt(6), pt(18))
        case .image:
            return (pt(6), pt(8))
        case .frontmatter:
            return (0, pt(34))
        case .thematicBreak:
            return (pt(26), pt(26))
        default:
            return (0, 0)
        }
    }

    /// Code-card padding scaled to the current ramp.
    ///
    /// Stamped onto the card's paragraphs so `CodeCardLayoutFragment` paints exactly the
    /// spacing accounted for here — the fragment has no ramp of its own to scale with.
    public var codeCardInsets: CodeCardInsets {
        let body = (CardChrome.codeBodyPadding * ramp.scale).rounded()
        return CodeCardInsets(
            header: (CardChrome.codeHeaderPadding * ramp.scale).rounded(),
            bodyTop: body,
            bodyBottom: body + abs(ramp.mono().descender).rounded()
        )
    }

    /// Paragraph style for one line of a code card.
    ///
    /// `leadingColumns` is the line's own indentation, in monospace columns. A wrapped
    /// continuation hangs *past* it rather than at a fixed offset from the card edge — with a
    /// fixed hanging indent the tail of an indented line lands to the left of the code it
    /// belongs to, so `Tensor {` or `binary block mask` reads as a new statement rather than as
    /// the continuation of the line above.
    public func codeLineStyle(leadingColumns: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.baseWritingDirection = .natural

        let scale = ramp.scale
        func pt(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

        // Pinned so every line of a card is the same height, whatever it holds.
        style.minimumLineHeight = ramp.monoLineHeight()
        style.maximumLineHeight = ramp.monoLineHeight()
        // No paragraph spacing: the card's padding is `CodeComponentView`'s layout, and the gap
        // around the card is the stack's. A line that carried spacing of its own would add a
        // dead band inside the card at each end.

        let advance = ("0" as NSString).size(withAttributes: [.font: ramp.mono()]).width
        let gutter = pt(CardChrome.codeGutter)
        style.firstLineHeadIndent = gutter
        // Two columns past the line's own indentation, so a continuation is unmistakably a
        // continuation.
        style.headIndent = gutter + (advance * CGFloat(leadingColumns + 2)).rounded()
        style.tailIndent = -gutter
        return style
    }

    /// Pins a line height to the ramp's published value, but never below what the font
    /// actually needs — a heading containing inline code would otherwise clip.
    private func pin(_ style: NSMutableParagraphStyle, _ height: CGFloat, font: NSFont) {
        let required = (font.ascender - font.descender + font.leading).rounded()
        let value = max(height, required)
        style.minimumLineHeight = value
        style.maximumLineHeight = value
    }

    // MARK: Font derivation

    private func weighted(_ font: NSFont, _ weight: NSFont.Weight) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private func scaled(_ font: NSFont, _ factor: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * factor).rounded()) ?? font
    }

    /// SF Mono has no italic face, so the monospaced reading font falls back to a slant.
    private func italic(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        if ramp.family == .monospaced {
            return [.font: font, .foregroundColor: Ink.body, .obliqueness: 0.2]
        }
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        if let italicFont = NSFont(descriptor: descriptor, size: font.pointSize) {
            return [.font: italicFont, .foregroundColor: Ink.body]
        }
        return [.font: font, .foregroundColor: Ink.body, .obliqueness: 0.2]
    }
}
