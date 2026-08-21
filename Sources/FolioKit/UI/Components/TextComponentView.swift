import AppKit

/// A component that can be dimmed by focus mode.
public protocol DimmableComponent: AnyObject {
    var isDimmed: Bool { get set }
}

/// Where a component sends a clicked link.
public protocol ComponentLinkDelegate: AnyObject {
    func component(_ view: NSView, didClickLink destination: String)
}

/// One prose component: a paragraph, heading, list, quote, or caption.
///
/// An `NSTextView` per component rather than one for the whole document. Selection, the caret's
/// word and line granularity, VoiceOver's static-text navigation and the link cursor all still
/// come from AppKit — they are simply scoped to the block, which is the unit a reader selects
/// in anyway. What the document-wide text view also brought, and this does not, is selection
/// that spans blocks and `NSTextFinder`.
///
/// The view is recycled: `configure(with:kind:)` is the whole of its state.
public final class TextComponentView: NSTextView, DimmableComponent {

    public weak var componentDelegate: ComponentLinkDelegate?

    private var kind: BlockKind = .paragraph
    /// The quote bar spans the text, not the paragraph spacing folded into this component's
    /// height, so it is trimmed by the first and last paragraph's own spacing.
    private var textInsets: (top: CGFloat, bottom: CGFloat) = (0, 0)

    public var isDimmed: Bool = false {
        didSet {
            guard isDimmed != oldValue else { return }
            alphaValue = isDimmed ? 0.34 : 1.0
        }
    }

    public init() {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        )
        // Padding would inset the text inside every component, so the measured height and the
        // laid-out height would agree while both disagreed with the prose measure.
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)

        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100), textContainer: container)

        isEditable = false
        // A non-selectable text view processes no mouse events at all — no selection, and no
        // link clicks either.
        isSelectable = true
        isRichText = false
        usesFontPanel = false
        isAutomaticLinkDetectionEnabled = false
        drawsBackground = false
        allowsUndo = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        // AppKit would otherwise underline links; the design uses color alone.
        linkTextAttributes = [
            .foregroundColor: Ink.link,
            .cursor: NSCursor.pointingHand,
        ]
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    public func configure(with attributed: NSAttributedString, kind: BlockKind) {
        self.kind = kind
        textContentStorage?.textStorage?.setAttributedString(attributed)
        setSelectedRange(NSRange(location: 0, length: 0))
        textInsets = Self.textInsets(of: attributed)
        isDimmed = false
        needsDisplay = true
    }

    /// Paragraph spacing that is laid out *inside* this component, and so has to be trimmed off
    /// a decoration that should span the text.
    ///
    /// The outer spacing — above the first paragraph and below the last — is not: TextKit
    /// collapses it at a container's edges and the stack applies it as the gap between
    /// components. Only a component holding several paragraphs has any inner spacing at all, and
    /// then the bar should still cover it, so this is zero either way. It stays as a named
    /// concept because the geometry is otherwise easy to get wrong from the drawing side.
    private static func textInsets(of attributed: NSAttributedString)
        -> (top: CGFloat, bottom: CGFloat) {
        (0, 0)
    }

    // MARK: Decoration

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard case .blockQuote = kind else { return }
        // The bar sits at the component's leading edge; the paragraph style's own indent is
        // what keeps the text clear of it.
        let bar = NSRect(x: 0, y: textInsets.top, width: QuoteBar.width,
                         height: max(0, bounds.height - textInsets.top - textInsets.bottom))
        Ink.accent.setFill()
        NSBezierPath(roundedRect: bar, xRadius: QuoteBar.width / 2,
                     yRadius: QuoteBar.width / 2).fill()
    }

    // MARK: Selection

    /// Releases every other component's selection when this one takes focus.
    ///
    /// Selection is per component, and AppKit keeps a text view's selection drawn — greyed —
    /// after it stops being first responder. Two blocks would look selected at once, and ⌘C
    /// would take only one of them.
    public override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        var ancestor = superview
        while let view = ancestor {
            if let stack = view as? DocumentStackView {
                stack.clearSelections(except: self)
                break
            }
            ancestor = view.superview
        }
        return true
    }

    // MARK: Links

    public override func clicked(onLink link: Any, at charIndex: Int) {
        let destination: String?
        switch link {
        case let string as String: destination = string
        case let string as NSString: destination = string as String
        case let url as URL: destination = url.absoluteString
        default: destination = nil
        }
        guard let destination else { return }
        componentDelegate?.component(self, didClickLink: destination)
    }

    // MARK: Measurement

    /// The height this component needs at `width`.
    ///
    /// Measured through the same TextKit 2 configuration the view uses — same container, same
    /// zero padding — because the stack positions every component from these numbers. A
    /// measurement taken any other way is a measurement that eventually disagrees with the
    /// layout and clips a last line.
    public static func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        TextMeasurer.shared.height(of: attributed, width: width)
    }
}

/// The quote bar's geometry, shared with whatever needs to indent past it.
public enum QuoteBar {
    public static let width: CGFloat = 3
}

/// An offscreen TextKit 2 stack kept for measuring components.
///
/// One instance, reused: building a layout manager per measurement dominated the cost of
/// laying out a long document.
final class TextMeasurer {
    static let shared = TextMeasurer()

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container = NSTextContainer(
        size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
    )

    private init() {
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
    }

    func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        container.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        contentStorage.textStorage?.setAttributedString(attributed)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return layoutManager.usageBoundsForTextContainer.height.rounded(.up)
    }
}
