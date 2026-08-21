import AppKit

/// The macOS HIG type ramp, scaled by the user's text-size preference.
///
/// Sizes are read from `NSFont.preferredFont(forTextStyle:)` rather than hardcoded, so the
/// ramp tracks the OS. At scale 1.0 they are the published macOS values:
/// Large Title 26/32, Title 1 22/26, Title 2 17/22, Title 3 15/20, Headline 13/16,
/// Body 13/16, Callout 12/15, Caption 1 10/13.
///
/// macOS has no Dynamic Type (Apple states this explicitly, and no public API reports the
/// System Settings text-size slider), so the app ships its own ⌘+/⌘−/⌘0 control. `scale`
/// spans 11/13 … 26/13, i.e. up to the HIG's "enlarge text by at least 200 percent" target.
public struct TypeRamp: Equatable {
    public let family: AppSettings.ReadingFont
    public let scale: CGFloat

    /// Body point size at scale 1.0. Clamped so presentation mode can't produce absurdity.
    public static let maxBodyPointSize: CGFloat = 40

    public init(family: AppSettings.ReadingFont, textSize: Int, presentationScale: CGFloat = 1) {
        self.family = family
        let base = NSFont.preferredFont(forTextStyle: .body).pointSize
        let requested = (CGFloat(textSize) / base) * presentationScale
        let ceiling = Self.maxBodyPointSize / base
        self.scale = min(requested, ceiling)
    }

    // MARK: Fonts

    public func body() -> NSFont { font(.body) }

    /// h1 → Large Title, h2 → Title 1, h3 → Title 2, h4 → Title 3, h5/h6 → Headline (bold).
    public func heading(level: Int) -> NSFont {
        switch level {
        case 1: return font(.largeTitle, weight: .semibold)
        case 2: return font(.title1, weight: .semibold)
        case 3: return font(.title2, weight: .semibold)
        case 4: return font(.title3, weight: .semibold)
        default: return font(.headline, weight: .bold)
        }
    }

    /// Card chrome, meta lines, captions, figure labels.
    public func caption() -> NSFont { font(.caption1) }

    /// Secondary chrome one step above caption — table cells, frontmatter values.
    public func callout() -> NSFont { font(.callout) }

    /// Fixed-pitch monospaced font for code bodies and raw mode.
    public func mono(relativeTo style: NSFont.TextStyle = .callout) -> NSFont {
        let size = scaled(NSFont.preferredFont(forTextStyle: style).pointSize)
        return Self.fixedPitchMono(ofSize: size)
    }

    /// Inline code sits slightly below the surrounding prose so the x-heights match.
    public func inlineCode() -> NSFont {
        Self.fixedPitchMono(ofSize: (body().pointSize * 0.92).rounded())
    }

    // MARK: Metrics

    /// Pinned line heights matching the HIG ramp's published values.
    public func leading(forHeadingLevel level: Int) -> CGFloat {
        let unscaled: CGFloat
        switch level {
        case 1: unscaled = 32
        case 2: unscaled = 26
        case 3: unscaled = 22
        case 4: unscaled = 20
        default: unscaled = 16
        }
        return (unscaled * scale).rounded()
    }

    public func monoLineHeight() -> CGFloat {
        let font = mono()
        return (font.ascender - font.descender + font.leading).rounded()
    }

    /// Average advance width of the body font, the classic typographic measure proxy.
    /// Correctly reflects that New York is narrower per character than SF.
    public func averageCharacterWidth() -> CGFloat {
        let alphabet = "abcdefghijklmnopqrstuvwxyz" as NSString
        let width = alphabet.size(withAttributes: [.font: body()]).width
        return width / CGFloat(alphabet.length)
    }

    // MARK: Resolution

    private func scaled(_ size: CGFloat) -> CGFloat {
        max(1, (size * scale).rounded())
    }

    /// Resolves a text style through the reading font's system design.
    ///
    /// Both `withDesign(_:)` and `NSFont(descriptor:size:)` return optionals and Apple does
    /// not document the nil conditions, so the SF fallback is mandatory. Never bundle a font
    /// file — Apple's license forbids embedding San Francisco or New York.
    private func font(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        let size = scaled(NSFont.preferredFont(forTextStyle: style).pointSize)
        let design: NSFontDescriptor.SystemDesign
        switch family {
        case .serif: design = .serif
        case .monospaced: design = .monospaced
        case .sansSerif: design = .default
        }

        var descriptor = NSFontDescriptor.preferredFontDescriptor(forTextStyle: style)
        if let designed = descriptor.withDesign(design) { descriptor = designed }
        if weight != .regular {
            descriptor = descriptor.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
            ])
        }
        if let resolved = NSFont(descriptor: descriptor, size: size) { return resolved }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// `monospacedSystemFont` is not actually fixed-pitch for box-drawing, CJK, or emoji
    /// glyphs — Apple's own note says to apply `fixedAdvance` to guarantee it. Code blocks
    /// and YAML frontmatter in raw mode both depend on columns lining up.
    static func fixedPitchMono(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: base]).width
        let descriptor = base.fontDescriptor.addingAttributes([.fixedAdvance: advance])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

extension NSFontDescriptor.AttributeName {
    /// Not surfaced in the Swift overlay, but a documented Core Text attribute.
    static let fixedAdvance = NSFontDescriptor.AttributeName(kCTFontFixedAdvanceAttribute as String)
}
