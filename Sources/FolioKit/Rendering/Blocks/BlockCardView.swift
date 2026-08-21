import AppKit

/// Shared geometry for every card-shaped block, so the three card styles cannot drift apart.
public enum CardChrome {
    public static let cornerRadius: CGFloat = 10
    public static let headerHeight: CGFloat = 32

    public static let bodyPadding = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

    /// Padding above a code card's header label, and again below it down to the divider, so
    /// the label sits centred on the strip instead of against the card's top edge.
    public static let codeHeaderPadding: CGFloat = 8
    /// Padding between the header divider and the first code line, mirrored under the last.
    public static let codeBodyPadding: CGFloat = 10
    /// Leading inset shared by the header label and the code, so the two cannot drift apart.
    public static let codeGutter: CGFloat = 14

    /// The design calls for a "0.5px" border, which means one device pixel — not half a point.
    /// `view` may be nil for drawing paths that have no view, such as a layout fragment.
    public static func hairlineWidth(in view: NSView?) -> CGFloat {
        1.0 / max(1, view?.window?.backingScaleFactor ?? 2)
    }
}

/// Base class for block widgets drawn as a rounded card.
///
/// Layer colors are assigned only inside `updateLayer()`. A `CGColor` does not adapt to
/// appearance changes, so storing one at init time would leave the card stuck in whichever
/// appearance happened to be current when it was built.
public class BlockCardView: NSView, DimmableComponent {

    /// Focus mode dims a card through this, the same protocol prose components use.
    public var isDimmed: Bool = false {
        didSet {
            guard isDimmed != oldValue else { return }
            alphaValue = isDimmed ? 0.34 : 1.0
        }
    }

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Deliberately *not* layer-backed. Colors are painted in `draw(_:)`, where AppKit has
        // already made the view's effective appearance current — so dynamic colors resolve
        // correctly and no CGColor is ever stored. Rounded corners come from a clip path.
        // A backing layer would also composite unreliably into an offscreen snapshot.
        translatesAutoresizingMaskIntoConstraints = false
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    /// Fill for the card body. Subclasses override for a code or diagram surface.
    open var cardFillColor: NSColor { Ink.cardFill }
    open var cardBorderColor: NSColor { Ink.hairline }

    public override func draw(_ dirtyRect: NSRect) {
        let hairline = CardChrome.hairlineWidth(in: self)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: hairline / 2, dy: hairline / 2),
            xRadius: CardChrome.cornerRadius,
            yRadius: CardChrome.cornerRadius
        )
        cardFillColor.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawCardContents(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        cardBorderColor.setStroke()
        path.lineWidth = hairline
        path.stroke()
    }

    /// Hook for subclasses that paint inside the card — a table's header band, for instance —
    /// so the border always strokes last and stays crisp.
    open func drawCardContents(in rect: NSRect) {}

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Colors are resolved during `draw(_:)`, so a redisplay is all that's needed.
        // Never set this from inside `draw`/`updateLayer` — that loops forever.
        needsDisplay = true
    }

    /// Measured height for an available width. Subclasses must be able to answer this without
    /// being installed in a view hierarchy, so the builder can pre-seed the size cache.
    open func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width, height: 0)
    }

    public override var intrinsicContentSize: NSSize {
        sizeThatFits(width: bounds.width > 0 ? bounds.width : 600)
    }
}

/// A card with a header strip: a label on the leading edge and optional trailing buttons.
public class HeaderedCardView: BlockCardView {

    public let headerLabel = NSTextField(labelWithString: "")
    public let headerAccessories = NSStackView()

    public var metrics: DocumentMetrics

    public init(metrics: DocumentMetrics, label: String) {
        self.metrics = metrics
        super.init(frame: .zero)

        headerLabel.font = TypeRamp.fixedPitchMono(ofSize: metrics.ramp.caption().pointSize)
        headerLabel.textColor = Ink.tertiary
        headerLabel.stringValue = label
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        headerAccessories.orientation = .horizontal
        headerAccessories.spacing = 8
        headerAccessories.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerLabel)
        addSubview(headerAccessories)

        // Centre on the header strip's midline rather than giving the label the strip's full
        // height: NSTextFieldCell top-aligns its text inside a taller frame, so a height
        // constraint would leave the label clipped against the card's top edge.
        let midline = topAnchor.anchorWithOffset(to: headerLabel.centerYAnchor)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            midline.constraint(equalToConstant: CardChrome.headerHeight / 2),

            headerAccessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            headerAccessories.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            headerAccessories.leadingAnchor.constraint(
                greaterThanOrEqualTo: headerLabel.trailingAnchor, constant: 8
            ),
        ])
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    /// The header strip and its underline are painted, not built from a box. An `NSBox`
    /// separator inside an attachment view resolved to its intrinsic width instead of spanning
    /// the card.
    public override func drawCardContents(in rect: NSRect) {
        let strip = NSRect(x: 0, y: 0, width: rect.width, height: CardChrome.headerHeight)
        Ink.cardFill.setFill()
        strip.fill()
        Ink.hairline.setFill()
        NSRect(x: 0, y: strip.maxY - CardChrome.hairlineWidth(in: self),
               width: rect.width, height: CardChrome.hairlineWidth(in: self)).fill()
    }

    /// Adds a borderless SF Symbol button to the header's trailing group.
    @discardableResult
    public func addHeaderButton(
        symbol: String,
        label: String,
        target: AnyObject?,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.contentTintColor = Ink.tertiary
        button.target = target
        button.action = action
        button.setAccessibilityLabel(label)
        button.toolTip = label
        headerAccessories.addArrangedSubview(button)
        return button
    }
}
