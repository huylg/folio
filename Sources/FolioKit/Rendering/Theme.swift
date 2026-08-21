import AppKit

/// Semantic colors for the reading pane.
///
/// Every member is a *computed* dynamic `NSColor` — never stored, never resolved to a
/// concrete value, never converted to `CGColor` outside a drawing callback. TextKit and
/// AppKit resolve them at draw time against the view's `effectiveAppearance`, which is what
/// makes light/dark adaptation free and what makes a theme change cost the renderer nothing.
///
/// Apple's rule, verbatim: "Avoid hard-coding system color values in your app… The actual
/// color values may fluctuate from release to release."
public enum Ink {

    // MARK: Text
    //
    // Three readable tiers plus one decorative one, derived by blending `labelColor` toward the
    // page rather than by reaching for `tertiaryLabelColor`/`quaternaryLabelColor`. Two measured
    // reasons:
    //
    // - Apple's lower label colors are tuned for placeholder and disabled states, not for text
    //   meant to be read. Against this reading surface `tertiaryLabelColor` measures 2.3:1
    //   against a 4.5:1 floor, which is why the grey text here was unreadable.
    // - `withAlphaComponent` cannot build the ramp: applied to the dynamic `labelColor` it
    //   silently resolves to zero alpha in light appearance, measuring 1.00:1.
    //
    // Ratios below are measured against the page. Blending is still evaluated per appearance
    // from `labelColor` and the page color, so nothing here is a hardcoded RGB value.

    /// Body prose and headings. ~12:1.
    public static var body: NSColor { .labelColor }
    public static var heading: NSColor { .labelColor }

    /// De-emphasised but fully readable: captions, meta lines, frontmatter values, deeper
    /// outline rows. ~8.5:1.
    public static var secondary: NSColor { labelBlended(0.26) }

    /// The quietest tier still meant to be *read*: card header labels, frontmatter keys, list
    /// markers. ~6.5:1.
    public static var tertiary: NSColor { labelBlended(0.41) }

    /// Decorative marks only — never text.
    public static var decorative: NSColor { labelBlended(0.58) }

    /// Retained for call sites that want a quiet *readable* mark, such as an unchecked
    /// checkbox. Deliberately not `decorative`: those were disappearing.
    public static var faint: NSColor { tertiary }

    public static var link: NSColor { .linkColor }
    public static var accent: NSColor { .controlAccentColor }

    /// `labelColor` blended `fraction` of the way toward the page, resolved per appearance.
    private static func labelBlended(_ fraction: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                guard let label = NSColor.labelColor.usingColorSpace(.sRGB),
                      let backdrop = Ink.page.usingColorSpace(.sRGB),
                      let blended = label.blended(withFraction: fraction, of: backdrop)
                else { return }
                result = blended
            }
            return result
        }
    }

    // MARK: Surfaces

    public static var page: NSColor { .textBackgroundColor }
    public static var mark: NSColor { .findHighlightColor }

    /// `separatorColor` is documented as unsuitable for split-view and window-chrome
    /// dividers, but is correct for in-content hairlines like card borders and rules.
    public static var hairline: NSColor {
        increaseContrast ? labelBlended(0.45) : .separatorColor
    }

    /// Slightly stronger than `hairline` — node borders and table frames need to read
    /// against a filled card, where a 0.08-alpha line is invisible.
    public static var hairlineStrong: NSColor {
        increaseContrast ? labelBlended(0.35) : fill(.tertiary)
    }

    /// A table's header band, and its alternating body rows.
    ///
    /// Ruling every row with `hairline` turned a long table into a ledger — for a table a reader
    /// scans down, a band is quieter and easier to follow than a line. Two explicit steps rather
    /// than the system fill tiers, which in dark mode are 0.8%, 2.7% and 4.7% white: too close
    /// together to build a header, a stripe, and a body out of.
    public static var tableHeaderFill: NSColor { NSColor.labelColor.withAlphaComponent(0.07) }
    public static var tableStripe: NSColor { NSColor.labelColor.withAlphaComponent(0.03) }

    public static var cardFill: NSColor { fill(.quaternary) }
    public static var cardFillStrong: NSColor { fill(.tertiary) }
    /// An opaque step off the page rather than a translucent overlay: a 13% grey over a
    /// near-black page is too small a difference for the card to read as a surface.
    public static var codeBackground: NSColor {
        NSColor(srgbRed: 0.141, green: 0.141, blue: 0.149, alpha: 1)
    }

    /// Diagram canvas — a touch lighter than a code body so a drawn diagram reads as a surface
    /// rather than a code listing.
    public static var diagramBackground: NSColor {
        NSColor(srgbRed: 0.137, green: 0.137, blue: 0.145, alpha: 1)
    }

    /// Accent-derived fill for tinted diagram nodes. `cardFillStrong` is grey and cannot
    /// substitute — a tinted node needs a tint-derived fill.
    public static var tintFill: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.28)
    }

    // MARK: Syntax

    /// Xcode-family palette built from adaptable system colors rather than CSS hexes.
    ///
    /// Contrast note, stated rather than hidden: `.systemOrange` on a light code background
    /// measures roughly 2.2:1. Syntax colors target 4.5:1 (Xcode's own palette does not reach
    /// 7:1 either); the 7:1 target applies to body prose and card chrome.
    public static func syntax(_ token: SyntaxHighlighter.TokenClass) -> NSColor {
        let base: NSColor
        switch token {
        case .keyword: base = .systemPurple
        case .function: base = .systemBlue
        case .string: base = .systemRed
        case .number: base = .systemOrange
        case .comment:
            // `.systemGray` against a code background measures under the floor, and a comment
            // is prose that people actually read.
            return labelBlended(0.34)
        }
        // Lifted toward white: on a dark code surface the raw system hues land just under the
        // 4.5:1 floor — systemPurple measures 4.27:1.
        let lift: CGFloat = increaseContrast ? 0.34 : 0.18
        return base.blending(lift, toward: .white) ?? base
    }

    // MARK: Accessibility display settings

    /// These must be observed on `NSWorkspace.shared.notificationCenter`; registering on
    /// `NotificationCenter.default` fails silently.
    public static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    public static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Fill fallback

    enum FillLevel { case tertiary, quaternary, quinary }

    /// `NSColor.systemFill` and its siblings are macOS 14+; this package's floor is 13.
    ///
    /// This is the **only** place in the rendering layer where RGB literals are acceptable,
    /// deliberately confined to one function so there is exactly one thing to delete when the
    /// deployment target rises. The values are Apple's own published fill greys.
    static func fill(_ level: FillLevel) -> NSColor {
        if #available(macOS 14, *) {
            switch level {
            case .tertiary: return .tertiarySystemFill
            case .quaternary: return .quaternarySystemFill
            case .quinary: return .quinarySystemFill
            }
        }
        let alpha: CGFloat
        switch level {
        case .tertiary: alpha = 0.24
        case .quaternary: alpha = 0.18
        case .quinary: alpha = 0.13
        }
        return NSColor(srgbRed: 120.0 / 255, green: 120.0 / 255, blue: 128.0 / 255, alpha: alpha)
    }
}

// MARK: - Tag palette

/// Colors for frontmatter tag pills and sidebar tag rows.
///
/// The document card previously assigned colors positionally (`i % 6`) while the sidebar
/// hashed the tag string, so the same tag rendered in two different colors. Both now go
/// through `slot(for:)`. Hash wins over positional because positional is meaningless in the
/// sidebar's alphabetized list and shifts whenever an author reorders `tags:` in frontmatter.
public enum TagPalette {
    public static let slotCount = 6

    private static let bases: [NSColor] = [
        .systemBlue, .systemPurple, .systemGreen, .systemOrange, .systemTeal, .systemPink,
    ]

    /// Preserved verbatim from the original sidebar implementation so existing tag colors
    /// do not shift for current users.
    public static func slot(for tag: String) -> Int {
        var hash = 0
        for scalar in tag.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        return abs(hash) % slotCount
    }

    public static func base(for tag: String) -> NSColor { bases[slot(for: tag)] }

    /// A pill's text must be blended toward black/white per appearance — raw `.systemGreen`
    /// on a 12%-green fill is unreadable.
    public static func pill(for tag: String) -> (fill: NSColor, text: NSColor) {
        let base = base(for: tag)
        if Ink.increaseContrast {
            return (Ink.cardFillStrong, Ink.body)
        }
        let fill = base.withAlphaComponent(0.28)
        let text = base.blending(0.45, toward: .white) ?? NSColor.labelColor
        return (fill, text)
    }
}

// MARK: - Helpers

extension NSColor {
    /// `blended(withFraction:of:)` requires matching color spaces and returns an optional;
    /// both are real crash sources, so conversion happens here once.
    func blending(_ fraction: CGFloat, toward other: NSColor) -> NSColor? {
        guard let from = usingColorSpace(.sRGB), let to = other.usingColorSpace(.sRGB) else {
            return nil
        }
        return from.blended(withFraction: fraction, of: to)
    }

    /// sRGB components resolved for `appearance`.
    func components(in appearance: NSAppearance) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        var result: (CGFloat, CGFloat, CGFloat, CGFloat)?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = self.usingColorSpace(.sRGB) else { return }
            result = (srgb.redComponent, srgb.greenComponent,
                      srgb.blueComponent, srgb.alphaComponent)
        }
        return result
    }

    static func linearize(_ c: CGFloat) -> CGFloat {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// This color composited over `base`, yielding an opaque color.
    ///
    /// The card and pill fills are translucent by design, so their *effective* background is
    /// the fill over whatever is behind it. Measuring against the raw translucent color scores
    /// white-on-near-white as 1:1 and is meaningless.
    public func flattened(over base: NSColor, appearance: NSAppearance) -> NSColor? {
        guard let fg = components(in: appearance),
              let bg = base.components(in: appearance) else { return nil }
        return NSColor(srgbRed: fg.r * fg.a + bg.r * (1 - fg.a),
                       green: fg.g * fg.a + bg.g * (1 - fg.a),
                       blue: fg.b * fg.a + bg.b * (1 - fg.a),
                       alpha: 1)
    }

    /// WCAG contrast ratio against `background`.
    ///
    /// The label colors are translucent, so the foreground is composited over the background
    /// first. Measuring raw components scores a 30%-alpha near-white as if it were opaque
    /// white — which is exactly how an unreadable grey passed for legible.
    public func contrastRatio(on background: NSColor, appearance: NSAppearance) -> CGFloat? {
        guard let fg = components(in: appearance),
              let bg = background.components(in: appearance) else { return nil }

        func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
            0.2126 * NSColor.linearize(r)
                + 0.7152 * NSColor.linearize(g)
                + 0.0722 * NSColor.linearize(b)
        }

        let composited = luminance(
            fg.r * fg.a + bg.r * (1 - fg.a),
            fg.g * fg.a + bg.g * (1 - fg.a),
            fg.b * fg.a + bg.b * (1 - fg.a)
        )
        let back = luminance(bg.r, bg.g, bg.b)
        let lighter = max(composited, back), darker = min(composited, back)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
