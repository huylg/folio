import AppKit

/// The press-to-peek gesture's state, separated from the table so the transitions can be
/// tested without synthesizing mouse events.
///
/// A quick click navigates; a press that crosses the hold threshold (or force-clicks) becomes
/// a preview, and its release is swallowed — peeking at a section must not also go there.
/// The release leaves the card up: from there it belongs to the dimmed backdrop, and the next
/// click anywhere outside it closes it.
final class OutlinePressPreviewState {

    enum Effect: Equatable {
        case none
        /// Present the card for a row (-1: pointer off the rows, keep the card hidden).
        case show(Int)
        /// The card is up and the pointer scrubbed to another row (-1 hides, press keeps going).
        case update(Int)
        /// Released after a preview: the card stays up, pinned; navigate nowhere.
        case pin
        /// Released before the threshold on the pressed row: a plain click.
        case click(Int)
    }

    private(set) var pressedRow = -1
    private(set) var isPreviewing = false
    private var previewRow = -1

    func pressBegan(row: Int) {
        pressedRow = row
        isPreviewing = false
        previewRow = -1
    }

    /// The hold timer elapsed with the button still down.
    func holdFired(pointerRow: Int) -> Effect {
        guard pressedRow >= 0, !isPreviewing else { return .none }
        isPreviewing = true
        previewRow = pointerRow
        return .show(pointerRow)
    }

    /// A force click is the same preview, sooner.
    func forceClicked(pointerRow: Int) -> Effect {
        holdFired(pointerRow: pointerRow)
    }

    func pointerMoved(toRow row: Int) -> Effect {
        guard isPreviewing, row != previewRow else { return .none }
        previewRow = row
        return .update(row)
    }

    func released(pointerRow: Int) -> Effect {
        defer { cancel() }
        guard pressedRow >= 0 else { return .none }
        if isPreviewing { return .pin }
        // Released elsewhere than it was pressed: not a click, matching NSTableView's feel.
        return pointerRow == pressedRow ? .click(pointerRow) : .none
    }

    func cancel() {
        pressedRow = -1
        isPreviewing = false
        previewRow = -1
    }
}

/// The Safari-link-preview-style peek card: an arrowless rounded panel beside the sidebar
/// showing a section's content while its outline row is pressed.
///
/// A borderless child window rather than an `NSPopover`, which always draws an anchor arrow
/// and its own bubble chrome. The panel never activates and never becomes key.
///
/// Its content is a `DocumentStackView` — the reading pane's own engine, given the section's
/// own components — so every block is drawn by the code that draws it on the page: a table is
/// the table view, a diagram is the diagram, a code card keeps its highlighting and header,
/// and the card cannot drift from the document it is previewing.
///
/// While the card is up, the window behind it is dimmed by an overlay that owns dismissal:
/// releasing the press pins the card, and the next click (or scroll) anywhere outside it —
/// which lands on the overlay — closes it. A click on the card itself lands on the panel and
/// does nothing. The press that summoned the card is unaffected by the overlay appearing
/// beneath the pointer: AppKit keeps delivering a captured press's events to the table.
final class OutlinePreviewController {

    /// Fixed, rather than shrunk to the content as it was while the card held a flat string
    /// of prose: components lay out to the column they are given, and a table or diagram
    /// squeezed to a narrower card is a different rendering — the thing this card is not
    /// allowed to be.
    static let cardWidth: CGFloat = 460
    static let maxContentHeight: CGFloat = 500
    static let padding: CGFloat = 14
    /// The title strip, drawn like the main window's own titlebar.
    static let headerHeight: CGFloat = 34
    /// Continuous and window-sized, matching the app's own chrome rather than a tooltip's.
    static let cornerRadius: CGFloat = 16
    /// The gap between the sidebar's edge and the card.
    static let anchorGap: CGFloat = 10
    /// Entrance scale, the Safari zoom-in feel.
    static let appearScale: CGFloat = 0.96
    static var appearDuration: TimeInterval = 0.15
    static var fadeOutDuration: TimeInterval = 0.10

    /// Asked for when the reader clicks or scrolls outside the pinned card, or the window
    /// resizes or resigns key under it. The owner ends the whole gesture, not just the card.
    var onDismissRequest: (() -> Void)?

    private var panel: NSPanel?
    private let card = PreviewCardView()
    private let titleField = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let host = PreviewBlockHost()
    private let stackView = DocumentStackView(metrics: DocumentMetrics(settings: .shared))
    private let dimming = DimmingView()
    private var windowObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var scrollObserver: NSObjectProtocol?
    /// Whether the current content is taller than the card and scrolls inside it.
    private var contentOverflows = false
    private(set) var isShown = false

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        unwatch()
    }

    /// Presents (or, if already up, moves and refills) the card for a row.
    func show(
        _ section: SectionPreview, title: String,
        anchoredToRow row: Int, in tableView: NSTableView
    ) {
        guard let window = tableView.window else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let fullHeight = fill(with: section)
        guard fullHeight > 0 else {
            hide()
            return
        }
        let visibleHeight = min(fullHeight, Self.maxContentHeight)
        contentOverflows = fullHeight > visibleHeight
        let cardSize = NSSize(
            width: Self.cardWidth,
            height: Self.headerHeight + visibleHeight + Self.padding * 2
        )

        titleField.stringValue = title

        let rowRect = tableView.convert(tableView.rect(ofRow: row), to: nil)
        let rowScreen = window.convertToScreen(rowRect)
        let frame = clampedFrame(for: cardSize, besideRow: rowScreen, on: window.screen)

        layoutContent(cardSize: cardSize, fullContentHeight: fullHeight)
        // A new section starts at its top, and the fade only claims "more below" while there is.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        stackView.populateVisible()
        updateBottomFade()

        if isShown {
            // Scrubbing: same card, new row. Moved without the entrance animation — the card
            // tracking rows should read like one object following the pointer.
            panel.setFrame(frame, display: true)
            return
        }

        isShown = true
        presentDimming(in: window)
        watch(window)
        window.addChildWindow(panel, ordered: .above)
        if Ink.reduceMotion {
            panel.alphaValue = 1
            panel.setFrame(frame, display: true)
            panel.orderFront(nil)
            return
        }
        // Zoom in from slightly small, centered on the final rect, fading up.
        let start = NSRect(
            x: frame.midX - frame.width * Self.appearScale / 2,
            y: frame.midY - frame.height * Self.appearScale / 2,
            width: frame.width * Self.appearScale,
            height: frame.height * Self.appearScale
        )
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Loads the section into the stack and measures it, returning the full content height.
    ///
    /// The size cache is cleared first because it is keyed by component index, and the card's
    /// components are a fresh slice numbered from zero on every row: scrubbing from a section
    /// that opens with a paragraph to one that opens with a table would otherwise lay the
    /// table out at the paragraph's cached height.
    private func fill(with section: SectionPreview) -> CGFloat {
        host.metrics = section.metrics
        host.sizeCache.removeAll()
        let contentWidth = Self.cardWidth - Self.padding * 2
        stackView.columnCount = 1
        stackView.columnWidth = contentWidth
        // No pagination in a card: one column, running on for as long as the section is.
        stackView.spreadHeight = 0
        stackView.setComponents(section.components, metrics: section.metrics)
        stackView.setFrameSize(NSSize(width: contentWidth, height: stackView.frame.height))
        // Measured explicitly rather than through `layoutSubtreeIfNeeded`: the card's size is
        // derived from this number before the panel has ever been shown, and AppKit's layout
        // pass is not guaranteed to have visited a view that is not yet on screen.
        stackView.ensureMeasured()
        return stackView.contentHeight
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        unwatch()
        let close = { [dimming] in
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.alphaValue = 1
            dimming.removeFromSuperview()
            dimming.alphaValue = 1
        }
        if Ink.reduceMotion {
            close()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
            dimming.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A card re-shown mid-fade has already flipped `isShown` back on.
            guard self?.isShown != true else { return }
            close()
        })
    }

    // MARK: Backdrop

    /// Dims everything behind the card. The overlay sits over the window's content, so it is
    /// also what an outside click lands on — dismissal and dimming are one object, and the
    /// first click closes the card without also activating whatever was under the pointer.
    private func presentDimming(in window: NSWindow) {
        guard let content = window.contentView else { return }
        dimming.onDismiss = { [weak self] in self?.onDismissRequest?() }
        if dimming.superview !== content {
            dimming.frame = content.bounds
            dimming.autoresizingMask = [.width, .height]
            content.addSubview(dimming)
        }
        if Ink.reduceMotion {
            dimming.alphaValue = 1
            return
        }
        dimming.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimming.animator().alphaValue = 1
        }
    }

    /// A pinned card cannot outlive the geometry it is anchored to or a window that is no
    /// longer in front: a resize reflows the rows, and losing key means the reader left.
    /// Escape closes it the way it closes any transient panel.
    private func watch(_ window: NSWindow) {
        unwatch()
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                self?.onDismissRequest?()
            })
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape
            self?.onDismissRequest?()
            return nil
        }
    }

    private func unwatch() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: Construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // The panel absorbs clicks on itself: the card is "inside", everything that lands on
        // the dimming overlay beneath is "outside" and dismisses. Non-activating, so even an
        // absorbed click never moves key or focus.
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none

        // The reading pane's engine, drawing the section's own components. The card supplies
        // its own chrome, so the page's top and bottom breathing room is dropped — see
        // `DocumentStackView.contentInsets`.
        stackView.host = host
        stackView.contentInsets = (top: 0, bottom: 0)

        // Content taller than the card scrolls inside it; the caps in
        // `SectionPreviewBuilder` are only a safety bound on a giant section.
        scrollView.documentView = stackView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            // The stack populates only what is near the viewport, so scrolling the card has
            // to ask for the components that just came into it.
            self?.stackView.populateVisible()
            self?.updateBottomFade()
        }

        // The header reads like the main window's titlebar: the section's name in title
        // weight over a hairline, so the card presents as a small window of the app.
        titleField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = Ink.body
        titleField.lineBreakMode = .byTruncatingTail
        separator.boxType = .separator

        card.translatesAutoresizingMaskIntoConstraints = true
        titleField.translatesAutoresizingMaskIntoConstraints = true
        separator.translatesAutoresizingMaskIntoConstraints = true
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        card.addSubview(titleField)
        card.addSubview(separator)
        card.addSubview(scrollView)
        panel.contentView = card
        return panel
    }

    private func layoutContent(cardSize: NSSize, fullContentHeight: CGFloat) {
        card.frame = NSRect(origin: .zero, size: cardSize)
        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(
            x: Self.padding,
            y: cardSize.height - Self.headerHeight + (Self.headerHeight - titleHeight) / 2,
            width: cardSize.width - Self.padding * 2,
            height: titleHeight
        )
        separator.frame = NSRect(
            x: 0, y: cardSize.height - Self.headerHeight, width: cardSize.width, height: 1
        )
        scrollView.frame = NSRect(
            x: Self.padding, y: Self.padding,
            width: cardSize.width - Self.padding * 2,
            height: cardSize.height - Self.headerHeight - Self.padding * 2
        )
        stackView.frame = NSRect(
            x: 0, y: 0,
            width: scrollView.contentSize.width,
            height: max(fullContentHeight, scrollView.contentSize.height)
        )
    }

    /// The fade at the card's bottom edge means "there is more below". It has to retract at
    /// the end of the content, or it would sit over the last line claiming otherwise.
    private func updateBottomFade() {
        guard contentOverflows else {
            card.showsBottomFade = false
            return
        }
        let clip = scrollView.contentView.bounds
        card.showsBottomFade = clip.maxY < stackView.frame.height - 1
    }

    /// The card sits to the right of the row, vertically centered on it, kept on screen.
    private func clampedFrame(
        for size: NSSize, besideRow rowScreen: NSRect, on screen: NSScreen?
    ) -> NSRect {
        var frame = NSRect(
            x: rowScreen.maxX + Self.anchorGap,
            y: rowScreen.midY - size.height / 2,
            width: size.width, height: size.height
        )
        guard let visible = screen?.visibleFrame else { return frame }
        frame.origin.x = min(frame.origin.x, visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY),
                             visible.maxY - frame.height)
        return frame
    }

}

/// The peek card's block host.
///
/// Deliberately its own rather than the reading pane's. `BlockSizeCache` is keyed by component
/// index, and the card's components are a slice numbered from zero, so sharing the pane's
/// cache would hand the card heights that were measured for entirely different blocks.
///
/// The card is a peek, so a link in it opens nothing — no `linkDelegate` is set and open
/// requests are dropped. A copy button still copies, which costs nothing and is what the same
/// card on the page would do.
private final class PreviewBlockHost: BlockHost {

    var metrics = DocumentMetrics(settings: .shared)
    var blockMetrics: DocumentMetrics { metrics }
    let sizeCache = BlockSizeCache()
    let diagramLayouts = DiagramLayoutCache()
    var pendingWorkCount = 0

    func blockRequestsOpen(_ destination: String) {}

    func blockRequestsCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The dimmed backdrop behind a pinned card.
///
/// It is deliberately a control as well as a tint: any click or scroll that lands on it asks
/// for dismissal and goes no further, so closing the card can never accidentally follow a
/// link or move the reading position underneath it.
private final class DimmingView: NSView {

    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    }

    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }
    override func otherMouseDown(with event: NSEvent) { onDismiss?() }
    override func scrollWheel(with event: NSEvent) { onDismiss?() }
}

/// The card's surface: rounded, hairline-bordered, on the page color, with an optional fade
/// at the bottom edge when the content was clipped.
private final class PreviewCardView: NSView {

    /// How much of the card's bottom the clipped-content fade covers.
    private static let fadeHeight: CGFloat = 44

    private let fade = CAGradientLayer()

    var showsBottomFade = false {
        didSet { if showsBottomFade != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = OutlinePreviewController.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Ink.page.cgColor
            layer.borderColor = Ink.hairlineStrong.cgColor
            fade.colors = [
                Ink.page.withAlphaComponent(0).cgColor,
                Ink.page.cgColor,
            ]
        }
        layer.borderWidth = 1

        if showsBottomFade {
            if fade.superlayer == nil { layer.addSublayer(fade) }
            fade.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.fadeHeight)
            // The view is unflipped, so layer y = 0 is the bottom edge; the gradient runs
            // from transparent at its top down to the page color at the card's edge.
            fade.startPoint = CGPoint(x: 0.5, y: 1)
            fade.endPoint = CGPoint(x: 0.5, y: 0)
        } else {
            fade.removeFromSuperlayer()
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
