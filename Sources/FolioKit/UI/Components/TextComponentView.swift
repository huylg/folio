import AppKit

/// A component that can be dimmed by focus mode.
public protocol DimmableComponent: AnyObject {
    var isDimmed: Bool { get set }
}

/// Where a component sends a clicked link.
public protocol ComponentLinkDelegate: AnyObject {
    func component(_ view: NSView, didClickLink destination: String)
}

/// Where a component sends a pointer resting on a link, for the hover peek card.
///
/// Consulted *before* the hover engages: a destination with nothing to peek — a mailto,
/// a non-markdown file, a section with no body — never starts a hover at all.
public protocol ComponentLinkPeekDelegate: AnyObject {
    /// Whether hovering `destination` could show a peek at all.
    func component(_ view: NSView, canPeekLink destination: String) -> Bool
    /// The pointer rested on `destination`: show the peek as a hover glance — no backdrop,
    /// nothing beneath it changes. `rect` is the link's bounding rect in `view`'s
    /// coordinates — the card anchors beside it.
    func component(_ view: NSView, hoverPeekLink destination: String, anchoredTo rect: NSRect)
    /// The unpressed pointer left the hovered link. The owner decides whether the card goes —
    /// a pointer travelling onto the card is still reading it.
    func componentHoverLeftLink(_ view: NSView)
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
    public weak var peekDelegate: ComponentLinkPeekDelegate?

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

    /// How many times any prose view has been configured, ever. Configuring is the expensive
    /// thing a reflow can do to a view — a full TextKit relayout — so the tests that matter
    /// assert it does not happen to views whose content did not change.
    static var configureCount = 0

    public func configure(with attributed: NSAttributedString, kind: BlockKind) {
        Self.configureCount += 1
        self.kind = kind
        // The view is recycled; a hover from its previous life must not outlive the content
        // it was hovering on.
        cancelLinkHover()
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
        guard let destination = Self.destination(of: link) else { return }
        componentDelegate?.component(self, didClickLink: destination)
    }

    /// The string a `.link` attribute's value points at, whichever type the builder stored.
    private static func destination(of link: Any) -> String? {
        switch link {
        case let string as String: return string
        case let string as NSString: return string as String
        case let url as URL: return url.absoluteString
        default: return nil
        }
    }

    // MARK: Hover-to-peek

    /// Ends a link hover in flight without emitting anything; the peek's owner hides the card
    /// itself when the hover's end asks for dismissal.
    public func cancelLinkHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverLink = nil
        hoverPeekShown = false
    }

    /// How long the pointer rests on a link before the hover peek appears. A `static var` so
    /// tests can zero it.
    public static var linkHoverDelay: TimeInterval = 0.4

    private var hoverTimer: Timer?
    /// The link under the resting pointer, and whether its card is up.
    private var hoverLink: (destination: String, rect: NSRect)?
    private var hoverPeekShown = false
    private var hoverArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.mouseMoved` as well as enter/exit: the pointer crosses between links without ever
        // leaving the component.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard peekDelegate != nil else { return }
        hoverMoved(to: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverEnded()
    }

    /// Split from the event so tests can drive the hover without synthesizing tracking events.
    func hoverMoved(to point: NSPoint) {
        guard let peekDelegate else { return }
        // Still on the link it is already hovering (or timing toward): nothing changes.
        if let hoverLink, hoverLink.rect.contains(point) { return }
        guard let hit = link(at: point),
              peekDelegate.component(self, canPeekLink: hit.destination) else {
            hoverEnded()
            return
        }
        // Stepping straight from one link onto another ends the first hover cleanly first.
        hoverEnded()
        hoverLink = hit
        let timer = Timer(timeInterval: Self.linkHoverDelay, repeats: false) { [weak self] _ in
            guard let self, let hoverLink else { return }
            hoverPeekShown = true
            self.peekDelegate?.component(self, hoverPeekLink: hoverLink.destination,
                                         anchoredTo: hoverLink.rect)
        }
        RunLoop.current.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func hoverEnded() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        let wasShown = hoverPeekShown
        hoverLink = nil
        hoverPeekShown = false
        if wasShown { peekDelegate?.componentHoverLeftLink(self) }
    }

    /// The link under `point`, with its bounding rect in view coordinates.
    ///
    /// The insertion index alone over-matches: the empty space past a line that ends
    /// in a link resolves to the link's last character. The laid-out segment rects are the
    /// truth of where the link is, so the hit is confirmed against them — and they double as
    /// the card's anchor.
    func link(at point: NSPoint) -> (destination: String, rect: NSRect)? {
        guard let storage = textContentStorage?.textStorage, storage.length > 0 else {
            return nil
        }
        let index = characterIndexForInsertion(at: point)
        // The insertion index sits *between* characters, so the link may be on either side.
        for candidate in [index, index - 1] where storage.length > candidate && candidate >= 0 {
            var range = NSRange()
            guard let value = storage.attribute(
                .link, at: candidate, longestEffectiveRange: &range,
                in: NSRange(location: 0, length: storage.length)
            ), let destination = Self.destination(of: value) else { continue }
            guard let rect = boundingRect(of: range), rect.contains(point) else { continue }
            return (destination, rect)
        }
        return nil
    }

    /// The union of the laid-out segment rects for `range`, in view coordinates.
    private func boundingRect(of range: NSRange) -> NSRect? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location,
                                                  offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        layoutManager.ensureLayout(for: textRange)
        var union: NSRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard,
                                            options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        // The container's origin is the view's: `textContainerInset` is zero and the container
        // has no line fragment padding.
        return union
    }

    /// Where the first link to `destination` was laid out, for tests that need somewhere to
    /// hover.
    func linkRectForTests(destination: String) -> NSRect? {
        guard let storage = textContentStorage?.textStorage, storage.length > 0 else {
            return nil
        }
        var found: NSRect?
        storage.enumerateAttribute(
            .link, in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard let value, Self.destination(of: value) == destination else { return }
            found = boundingRect(of: range)
            stop.pointee = true
        }
        return found
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
        size(of: attributed, width: width).height
    }

    /// How many layouts have ever been run. Laying out is the expensive thing this class
    /// does — a whole transcript per call — so the tests that matter are the ones asserting
    /// the callers that cache don't come back for the same text.
    private(set) var measures = 0

    /// The space the text actually uses at `width`: the height, and the widest laid-out line.
    /// The width lets a container be sized to its content — narrowing it to this value cannot
    /// change the wrapping, because every line already fits.
    func size(of attributed: NSAttributedString, width: CGFloat) -> NSSize {
        guard attributed.length > 0 else { return .zero }
        measures += 1
        container.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        contentStorage.textStorage?.setAttributedString(attributed)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let used = layoutManager.usageBoundsForTextContainer
        return NSSize(width: used.width.rounded(.up), height: used.height.rounded(.up))
    }
}
