import AppKit

/// The one place an update ever announces itself: a small capsule in the titlebar.
///
/// A badge rather than a sheet on purpose. An update is not an errand the reader started, and a
/// modal that interrupts a document to talk about the app is exactly the interruption Folio is
/// meant not to be. The capsule is legible at a glance, ignorable indefinitely, and clicking it is
/// the whole interaction: available → downloading → restart.
final class UpdateBadgeView: NSButton {

    /// Padding around the label, which is what makes it a pill rather than a word.
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 4

    private var isHovered = false { didSet { needsDisplay = true } }

    /// Builds the secondary-click menu, which is state-dependent and therefore cannot be a menu
    /// set once. Overriding `menu(for:)` rather than wiring the button's action to a right-click:
    /// `NSButton` does not send its action on the right button at all, so a click handler that
    /// inspected `NSApp.currentEvent` would never have run.
    var menuProvider: (() -> NSMenu?)?

    /// The colours a state paints in. Kept as a pair so contrast is decided once, here, rather
    /// than by whichever call site set a background last.
    struct Palette {
        let fill: NSColor
        let text: NSColor
    }

    private var palette = Palette(fill: Ink.accent, text: .white) {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: 11, weight: .medium)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    /// The label and colours for a state, and nil when the state has nothing to say — which is
    /// what hides the badge entirely rather than leaving an empty pill in the titlebar.
    static func appearance(for state: UpdateState) -> (title: String, palette: Palette)? {
        switch state {
        case .idle:
            return nil
        case .checking:
            return ("Checking for Updates…", quiet)
        case .upToDate(let version):
            return ("Folio \(version) is up to date", quiet)
        case .available(let release):
            return ("Update Available: \(release.version)", loud)
        case .downloading(_, let fraction):
            return ("Downloading… \(Int((fraction * 100).rounded()))%", quiet)
        case .readyToInstall(let release, _):
            return ("Restart to Update to \(release.version)", loud)
        case .installing:
            return ("Installing…", quiet)
        case .failed:
            return ("Update Failed", failedPalette())
        }
    }

    /// The accent, for the two states that are asking for a click.
    ///
    /// Deepened rather than used as-is. `controlAccentColor` is whatever the reader picked in
    /// System Settings — yellow and orange are both on the menu — and white on the stock blue
    /// measures 4.0:1 against a 4.5:1 floor before anyone has changed anything. So the fill is
    /// darkened until the label clears the same floor the rest of the palette is held to, which
    /// keeps a pill legible on an accent this code has never seen.
    static var loud: Palette {
        Palette(fill: deepened(Ink.accent, until: .white, clears: readableFloor), text: .white)
    }

    /// Progress and outcomes, which are reporting rather than asking, so they sit quietly against
    /// the titlebar instead of competing with it.
    static var quiet: Palette { Palette(fill: Ink.cardFill, text: Ink.body) }

    static func failedPalette() -> Palette {
        Palette(fill: deepened(.systemRed, until: .white, clears: readableFloor), text: .white)
    }

    /// WCAG AA for small text — the floor `ContrastTests` holds the reading palette to, and the
    /// badge carries 11pt text.
    private static let readableFloor: CGFloat = 4.5

    /// Blends `base` toward black until `text` on it clears `target`.
    ///
    /// Dynamic, in the shape `Ink` uses: the blend is evaluated per appearance rather than frozen
    /// at one, so nothing here is a hardcoded RGB value. Monotonic and therefore terminating —
    /// white on black is 21:1 — but capped anyway so a colour space that will not convert cannot
    /// spin.
    private static func deepened(_ base: NSColor,
                                 until text: NSColor,
                                 clears target: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = base
            appearance.performAsCurrentDrawingAppearance {
                var fraction: CGFloat = 0
                while fraction <= 0.9 {
                    guard let candidate = base.blending(fraction, toward: .black) else { return }
                    result = candidate
                    let ratio = text.contrastRatio(on: candidate, appearance: appearance) ?? 0
                    if ratio >= target { return }
                    fraction += 0.05
                }
            }
            return result
        }
    }

    func apply(_ state: UpdateState) {
        guard let (text, palette) = Self.appearance(for: state) else {
            isHidden = true
            return
        }
        isHidden = false
        self.palette = palette
        title = text
        toolTip = Self.tooltip(for: state)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: palette.text,
        ])
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private static func tooltip(for state: UpdateState) -> String? {
        switch state {
        case .available(let release):
            return "Click to download Folio \(release.version)."
        case .readyToInstall:
            return "Click to install and relaunch Folio."
        case .downloading:
            return "Right-click to cancel."
        case .failed(let error):
            return error.message
        default:
            return nil
        }
    }

    // MARK: Layout and drawing

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + Self.horizontalPadding * 2,
                      height: ceil(text.height) + Self.verticalPadding * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        var fill = palette.fill
        if isHighlighted {
            fill = fill.blended(withFraction: 0.2, of: .black) ?? fill
        } else if isHovered {
            fill = fill.blended(withFraction: 0.12, of: .white) ?? fill
        }
        fill.setFill()
        path.fill()

        let text = attributedTitle
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Covers right-click and control-click both, which AppKit routes through here.
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func accessibilityLabel() -> String? { title }
}
