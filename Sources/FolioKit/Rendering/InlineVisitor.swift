import AppKit
import Markdown

/// Builds the attributed string for inline content.
///
/// Traits are carried down and resolved at the leaves rather than applied to a finished range
/// on the way back up. That ordering matters: applying an outer node's attributes to the range
/// its children already produced would overwrite them, so `**bold *and italic* **` would lose
/// the italic. Descending with a modified trait set instead composes correctly at any depth.
struct InlineVisitor: MarkupVisitor {
    typealias Result = NSAttributedString

    let metrics: DocumentMetrics
    let baseRole: InlineRole
    let baseURL: URL

    private var traits = Traits()

    init(metrics: DocumentMetrics, baseRole: InlineRole = .body, baseURL: URL) {
        self.metrics = metrics
        self.baseRole = baseRole
        self.baseURL = baseURL
    }

    struct Traits {
        var bold = false
        var italic = false
        var code = false
        var strikethrough = false
        var link: String?
        var script: Script = .none

        enum Script { case none, superscript, subscriptScript }
    }

    // MARK: Leaf resolution

    /// Composes the base role with the accumulated traits into concrete attributes.
    private func resolvedAttributes() -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any]

        if traits.code {
            attributes = metrics.attributes(for: .code)
        } else {
            attributes = metrics.attributes(for: baseRole)
            if traits.bold || traits.italic {
                let font = (attributes[.font] as? NSFont) ?? metrics.ramp.body()
                attributes[.font] = styled(font, bold: traits.bold, italic: traits.italic)
                // SF Mono has no italic face, so the monospaced reading font slants instead.
                if traits.italic, metrics.ramp.family == .monospaced {
                    attributes[.obliqueness] = 0.2
                }
                if traits.bold { attributes[.foregroundColor] = Ink.heading }
            }
        }

        if traits.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = Ink.secondary
        }

        switch traits.script {
        case .none:
            break
        case .superscript, .subscriptScript:
            let font = (attributes[.font] as? NSFont) ?? metrics.ramp.body()
            let smaller = NSFont(descriptor: font.fontDescriptor,
                                 size: (font.pointSize * 0.68).rounded()) ?? font
            attributes[.font] = smaller
            let shift = font.pointSize * (traits.script == .superscript ? 0.33 : -0.2)
            attributes[.baselineOffset] = shift.rounded()
            if traits.script == .superscript, traits.link == nil {
                attributes[.foregroundColor] = Ink.accent
            }
        }

        if let link = traits.link {
            // Stored as a raw string, not a URL: relative destinations with spaces (the sample
            // vault has one) make `URL(string:)` return nil, and resolution needs the document's
            // directory anyway. `DocumentTextView` resolves it on click.
            attributes[.link] = link as NSString
            attributes[.foregroundColor] = Ink.link
            attributes[.underlineStyle] = 0
            attributes[.cursor] = NSCursor.pointingHand
            attributes[.folioInlineRole] = InlineRole.link
        }

        return attributes
    }

    private func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var descriptor = font.fontDescriptor
        if italic {
            descriptor = descriptor.withSymbolicTraits(
                NSFontDescriptor.SymbolicTraits(rawValue: descriptor.symbolicTraits.rawValue)
                    .union(.italic)
            )
        }
        if bold {
            descriptor = descriptor.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]
            ])
        }
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private func leaf(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: resolvedAttributes())
    }

    // MARK: Composition

    mutating func defaultVisit(_ markup: Markup) -> NSAttributedString {
        children(of: markup)
    }

    private mutating func children(of markup: Markup) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in markup.children { out.append(visit(child)) }
        return out
    }

    /// Descends with a modified trait set, restoring it afterwards.
    private mutating func withTraits(
        _ transform: (inout Traits) -> Void,
        _ body: (inout InlineVisitor) -> NSAttributedString
    ) -> NSAttributedString {
        let saved = traits
        transform(&traits)
        let result = body(&self)
        traits = saved
        return result
    }

    // MARK: Nodes

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        leaf(text.string)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        withTraits({ $0.code = true }) { visitor in
            // Hair spaces stand in for horizontal padding until the rounded-pill layout
            // fragment lands; without them the background sits flush against the glyphs.
            visitor.leaf("\u{200A}" + inlineCode.code + "\u{200A}")
        }
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        withTraits({ $0.italic = true }) { $0.children(of: emphasis) }
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        withTraits({ $0.bold = true }) { $0.children(of: strong) }
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        withTraits({ $0.strikethrough = true }) { $0.children(of: strikethrough) }
    }

    mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
        let destination = link.destination ?? ""
        return withTraits({ $0.link = destination.isEmpty ? nil : destination }) {
            $0.children(of: link)
        }
    }

    mutating func visitImage(_ image: Markdown.Image) -> NSAttributedString {
        // Inline images (not a bare-image paragraph) render small, capped to the line box.
        let source = image.source ?? ""
        let alt = image.plainText
        let attachment = NSTextAttachment()
        let resolved = LinkRouter.resolve(source, relativeTo: baseURL)
        if case .file(let url) = resolved, let loaded = NSImage(contentsOf: url) {
            let cap = metrics.ramp.body().pointSize * 1.5
            let scale = min(1, cap / max(loaded.size.height, 1))
            loaded.size = NSSize(width: loaded.size.width * scale, height: loaded.size.height * scale)
            loaded.accessibilityDescription = alt
            attachment.image = loaded
        }
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttributes(
            [.font: metrics.ramp.body(), .folioCopyText: "![\(alt)](\(source))"],
            range: NSRange(location: 0, length: out.length)
        )
        if attachment.image == nil, !alt.isEmpty {
            return leaf(alt)
        }
        return out
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
        leaf(" ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
        // U+2028 breaks the line without starting a new paragraph. A "\n" here would begin a
        // fresh paragraph and pick up the block's full paragraph spacing.
        leaf("\u{2028}")
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSAttributedString {
        // Passing raw HTML through was only ever meaningful to a web view. An allowlist covers
        // what Markdown authors actually write; anything else contributes nothing, which
        // matches the *rendered* result readers saw before. Inner text still appears, since it
        // arrives as separate Text nodes.
        let tag = inlineHTML.rawHTML.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "</ >"))
            .components(separatedBy: CharacterSet(charactersIn: " \t")).first ?? ""
        let isClosing = inlineHTML.rawHTML.hasPrefix("</")

        switch tag {
        case "br":
            return leaf("\u{2028}")
        case "sup":
            traits.script = isClosing ? .none : .superscript
        case "sub":
            traits.script = isClosing ? .none : .subscriptScript
        case "b", "strong":
            traits.bold = !isClosing
        case "i", "em":
            traits.italic = !isClosing
        case "code", "kbd":
            traits.code = !isClosing
        case "del", "s", "strike":
            traits.strikethrough = !isClosing
        default:
            break
        }
        return NSAttributedString()
    }
}
