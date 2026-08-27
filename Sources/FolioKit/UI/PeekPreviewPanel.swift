import AppKit
import WebKit

/// The Safari-link-preview-style peek card: an arrowless rounded panel beside whatever the
/// pointer rests on — an outline row, a link in the page — showing the target's content for
/// as long as the hover lasts.
///
/// A borderless child window rather than an `NSPopover`, which always draws an anchor arrow
/// and its own bubble chrome. The panel never activates and never becomes key.
///
/// Its content is a `DocumentStackView` — the reading pane's own engine, given the section's
/// own components — so every block is drawn by the code that draws it on the page: a table is
/// the table view, a diagram is the diagram, a code card keeps its highlighting and header,
/// and the card cannot drift from the document it is previewing.
///
/// While the card is up, a light veil dims the window behind it — focusing the eye without
/// taking anything away: the veil never intercepts events, so the layer beneath keeps
/// hovering, scrolling, and clicking as before.
///
/// Owns nothing about the gesture: callers anchor it to a screen rect — a row's, a link's —
/// and call `show`/`hide` themselves as the pointer comes and goes.
final class PeekPreviewPanel {

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
    /// The gap between the anchor's edge and the card.
    static let anchorGap: CGFloat = 10
    /// What scrolling content gives up on the trailing edge for the overlay scroller, which
    /// otherwise draws over the last points of every line.
    static let scrollerGutter: CGFloat = 16
    /// Entrance scale, the Safari zoom-in feel.
    static let appearScale: CGFloat = 0.96
    static var appearDuration: TimeInterval = 0.15
    static var fadeOutDuration: TimeInterval = 0.10
    /// How dark the veil behind the card is. Light on purpose: it focuses the eye on the
    /// card without claiming the layer beneath is inert — which it is not, a hover glance
    /// leaves everything under it live.
    static let dimmingAlpha: CGFloat = 0.12

    /// Asked for when Escape is pressed, or the window resizes or resigns key under the card.
    /// The owner ends the whole hover, not just the card.
    var onDismissRequest: (() -> Void)?

    /// Fired when the pointer enters or leaves the card. Owners use it to keep the card up
    /// while it is being read — and scrolled — and to let it go once the pointer moves on.
    var onCardHoverChange: ((Bool) -> Void)?

    /// Where the pointer is, for the hover checks. Injected so a test's card is not haunted by
    /// wherever the machine's real mouse happens to rest.
    static var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// Whether the pointer is currently over the card.
    var isPointerInsideCard: Bool {
        guard isShown, let panel else { return false }
        return panel.frame.contains(Self.pointerLocation())
    }

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
    /// The web preview's surface, created the first time an external link peeks.
    private var webView: WKWebView?
    private var webTitleObservation: NSKeyValueObservation?
    /// Whether the current content is taller than the card and scrolls inside it.
    private var contentOverflows = false
    private(set) var isShown = false

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        unwatch()
    }

    /// Presents (or, if already up, moves and refills) the card beside `anchor`, a rect in
    /// screen coordinates — an outline row's, a link's.
    ///
    /// The card is a glance: nothing beneath it changes, and the owner hides it when the
    /// pointer moves on.
    func show(
        _ section: SectionPreview, title: String,
        anchoredTo anchor: NSRect, in window: NSWindow
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let fullWidth = Self.cardWidth - Self.padding * 2
        var fullHeight = fill(with: section, width: fullWidth)
        guard fullHeight > 0 else {
            hide()
            return
        }
        if fullHeight > Self.maxContentHeight {
            // The content scrolls, so the overlay scroller exists — and it draws *over* the
            // clip's trailing edge. The column steps back from under it and is re-measured at
            // the narrower width, so the scroller rides an empty margin rather than the text.
            // A card that fits has no scroller and keeps the full width.
            fullHeight = fill(with: section, width: fullWidth - Self.scrollerGutter)
        }
        let visibleHeight = min(fullHeight, Self.maxContentHeight)
        contentOverflows = fullHeight > visibleHeight
        let cardSize = NSSize(
            width: Self.cardWidth,
            height: Self.headerHeight + visibleHeight + Self.padding * 2
        )

        titleField.stringValue = title
        // The card may have been a web preview a moment ago: the reading engine takes over.
        if let webView {
            webView.stopLoading()
            webView.isHidden = true
        }
        scrollView.isHidden = false

        layoutContent(cardSize: cardSize, fullContentHeight: fullHeight)
        // A new section starts at its top, and the fade only claims "more below" while there is.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        stackView.populateVisible()
        updateBottomFade()

        present(cardSize: cardSize, anchoredTo: anchor, in: window)
    }

    /// Presents (or moves) the card as a live web preview of `url` — for links that leave the
    /// vault entirely. The header starts as the host and takes the page's title once it loads,
    /// the way the section card's header names its section.
    func showWeb(_ url: URL, anchoredTo anchor: NSRect, in window: NSWindow) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let webView = ensureWebView()
        scrollView.isHidden = true
        webView.isHidden = false
        contentOverflows = false
        card.showsBottomFade = false
        titleField.stringValue = url.host ?? url.absoluteString

        // A page has no natural height the way a section does; the card is simply as large as
        // it is allowed to be, and the page scrolls inside it.
        let cardSize = NSSize(
            width: Self.cardWidth,
            height: Self.headerHeight + Self.maxContentHeight
        )
        layoutChrome(cardSize: cardSize)
        // Full bleed under the header: a web page supplies its own margins.
        webView.frame = NSRect(x: 0, y: 0, width: cardSize.width,
                               height: cardSize.height - Self.headerHeight)
        if webView.url != url { webView.load(URLRequest(url: url)) }

        present(cardSize: cardSize, anchoredTo: anchor, in: window)
    }

    /// The shared tail of both `show`s: places the sized card beside the anchor and runs the
    /// entrance — or, if the card is already up, moves it there.
    private func present(cardSize: NSSize, anchoredTo anchor: NSRect, in window: NSWindow) {
        guard let panel else { return }
        let frame = clampedFrame(for: cardSize, besideAnchor: anchor, on: window.screen)

        if isShown {
            // Same card, new anchor. Moved without the entrance animation — the card tracking
            // the pointer should read like one object following it.
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
    /// components are a fresh slice numbered from zero on every fill: scrubbing from a section
    /// that opens with a paragraph to one that opens with a table would otherwise lay the
    /// table out at the paragraph's cached height.
    private func fill(with section: SectionPreview, width: CGFloat) -> CGFloat {
        host.metrics = section.metrics
        host.sizeCache.removeAll()
        // The section's own run context: runs execute at the previewed document's root, and
        // their sessions join its store — the shared one when it is the current document,
        // which is what mirrors a console onto the reading pane. Set before `setComponents`,
        // so the fresh cards bind to their blocks' keys and adopt any existing consoles.
        host.runContext = section.runContext
        stackView.runContext = section.runContext
        stackView.columnCount = 1
        stackView.columnWidth = width
        // No pagination in a card: one column, running on for as long as the section is.
        stackView.spreadHeight = 0
        stackView.setComponents(section.components, metrics: section.metrics)
        stackView.setFrameSize(NSSize(width: width, height: stackView.frame.height))
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
        // A page that keeps loading — or playing — behind an ordered-out panel is pure waste.
        webView?.stopLoading()
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

    /// Lays the veil over the window's content while the card is up. It arrives with the
    /// card's own fade, and — unlike the card — never answers the pointer: everything under
    /// it keeps hovering, scrolling, and clicking as if it were not there.
    private func presentDimming(in window: NSWindow) {
        guard let content = window.contentView else { return }
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

    /// The card cannot outlive the geometry it is anchored to or a window that is no longer
    /// in front: a resize reflows the content, and losing key means the reader left.
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
        // The panel absorbs clicks on itself so a click into the card cannot fall through to
        // whatever sits beneath it. Non-activating, so even an absorbed click never moves key
        // or focus.
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none

        // The reading pane's engine, drawing the section's own components. The card supplies
        // its own chrome, so the page's top and bottom breathing room is dropped — see
        // `DocumentStackView.contentInsets`.
        stackView.host = host
        stackView.contentInsets = (top: 0, bottom: 0)
        // A run console unfolding inside the card changes a block's height after presentation
        // — the one thing that does — and the card grows to fit it.
        host.onBlockHeightChange = { [weak self] view in self?.blockGrew(view) }

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

        card.onHoverChange = { [weak self] inside in self?.onCardHoverChange?(inside) }

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

    /// The web preview's surface. One per panel, made on first use so a reader who never
    /// peeks an external link never pays for a web process.
    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.translatesAutoresizingMaskIntoConstraints = true
        card.addSubview(web)
        // The header starts as the host; the page's own title replaces it once known — but
        // never while the card has moved on to showing a section.
        webTitleObservation = web.observe(\.title) { [weak self] web, _ in
            guard let self, !web.isHidden, let title = web.title, !title.isEmpty else { return }
            titleField.stringValue = title
        }
        webView = web
        return web
    }

    /// The chrome every presentation shares: the card's own frame, the title strip, and the
    /// hairline under it.
    private func layoutChrome(cardSize: NSSize) {
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
    }

    private func layoutContent(cardSize: NSSize, fullContentHeight: CGFloat) {
        layoutChrome(cardSize: cardSize)
        scrollView.frame = NSRect(
            x: Self.padding, y: Self.padding,
            width: cardSize.width - Self.padding * 2,
            height: cardSize.height - Self.headerHeight - Self.padding * 2
        )
        stackView.frame = NSRect(
            x: 0, y: 0,
            // The width `fill` measured at — narrower than the clip when the content scrolls,
            // leaving the trailing gutter to the overlay scroller.
            width: stackView.frame.width,
            height: max(fullContentHeight, scrollView.contentSize.height)
        )
    }

    /// Re-sizes the card around a block whose height changed after presentation — a run
    /// console unfolding, folding away, or growing with live output.
    ///
    /// Strictly a re-measure, never a re-fill: `fill` calls `setComponents`, which recycles
    /// every view — the very card whose console is mid-animation included. The one cached
    /// height is dropped and the stack re-measured; the retained views survive that, and they
    /// survive the column narrowing below for the same reason.
    ///
    /// The card grows *downward*, top edge pinned — screen coordinates are unflipped, so that
    /// means holding `maxY`. Re-centering on the anchor would jiggle the card around its
    /// middle on every step of the unfold. Height still caps at `maxContentHeight`; past it
    /// the content scrolls inside the card, and the console itself caps and scrolls long
    /// before that.
    private func blockGrew(_ view: NSView) {
        guard isShown, let panel, !scrollView.isHidden else { return }
        stackView.remeasureComponent(containing: view)
        stackView.ensureMeasured()
        var fullHeight = stackView.contentHeight

        // Content just crossed into overflow: the column steps back from under the overlay
        // scroller, exactly as `show` does at presentation time, and is re-measured at the
        // narrower width.
        let gutterWidth = Self.cardWidth - Self.padding * 2 - Self.scrollerGutter
        if fullHeight > Self.maxContentHeight, stackView.columnWidth > gutterWidth {
            stackView.columnWidth = gutterWidth
            stackView.setFrameSize(NSSize(width: gutterWidth,
                                          height: stackView.frame.height))
            stackView.ensureMeasured()
            fullHeight = stackView.contentHeight
        }

        let visibleHeight = min(fullHeight, Self.maxContentHeight)
        contentOverflows = fullHeight > visibleHeight
        let cardSize = NSSize(
            width: Self.cardWidth,
            height: Self.headerHeight + visibleHeight + Self.padding * 2
        )

        var frame = panel.frame
        frame.origin.y = frame.maxY - cardSize.height
        frame.size = cardSize
        if let visible = panel.screen?.visibleFrame {
            frame.origin.y = min(max(frame.origin.y, visible.minY),
                                 visible.maxY - frame.height)
        }
        // Plain setFrame, no animator: the console's reveal timer is already driving this at
        // sixty steps a second, and an animation per step would fight the next one.
        panel.setFrame(frame, display: true)

        layoutContent(cardSize: cardSize, fullContentHeight: fullHeight)
        stackView.populateVisible()
        updateBottomFade()
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

    /// The card sits to the right of the anchor, vertically centered on it, kept on screen.
    private func clampedFrame(
        for size: NSSize, besideAnchor anchor: NSRect, on screen: NSScreen?
    ) -> NSRect {
        var frame = NSRect(
            x: (anchor.maxX + Self.anchorGap).rounded(),
            // Rounded: window frames are integral, and a fractional origin re-rounded on
            // every later setFrame — the grow path pins the top edge by reading the frame
            // back — walks the card a point at a time.
            y: (anchor.midY - size.height / 2).rounded(),
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
///
/// A shell block, though, runs: the click is the same consent it is on the page, and the run
/// writes into a `RunSession` — shared with the reading pane when the card previews the
/// current document, so the console appears on the block there too, and lives on if the card
/// closes mid-run. The command executes at the *previewed* document's root, which a cross-file
/// peek's context points at the target's own project.
private final class PreviewBlockHost: BlockHost {

    var metrics = DocumentMetrics(settings: .shared)
    var blockMetrics: DocumentMetrics { metrics }
    let sizeCache = BlockSizeCache()
    let diagramLayouts = DiagramLayoutCache()
    /// The card's own counter, deliberately not the reading pane's: snapshot quiescence
    /// watches the pane's host, and a peek's run is not the page's work.
    var pendingWorkCount = 0

    /// Where the current section's blocks run, and whose store their sessions join. Set on
    /// every fill; nil (no context on the preview) leaves the Run button inert.
    var runContext: RunContext?
    /// A block's height changed after presentation — a console unfolding — and the card must
    /// grow with it. The panel installs this.
    var onBlockHeightChange: ((NSView) -> Void)?

    func blockRequestsOpen(_ destination: String) {}

    func blockRequestsCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func blockRequestsRun(_ command: String,
                          onOutput: @escaping (TerminalSnapshot) -> Void,
                          completion: @escaping (ProcessRunner.Output?) -> Void) {
        guard let runContext else {
            completion(nil)
            return
        }
        pendingWorkCount += 1
        ProcessRunner.streamShell(command, at: runContext.rootURL,
                                  onOutput: onOutput) { [weak self] result in
            self?.pendingWorkCount -= 1
            completion(result)
        }
    }

    func blockHeightDidChange(_ view: NSView) {
        onBlockHeightChange?(view)
    }
}

/// The light veil behind a hover card, focusing the eye on it.
///
/// Deliberately a tint and nothing more: a hover glance must leave the layer beneath fully
/// live — the pointer keeps hovering rows and links, and a click still lands where it aims —
/// so the veil never answers hit-testing.
private final class DimmingView: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black
            .withAlphaComponent(PeekPreviewPanel.dimmingAlpha).cgColor
    }

    /// Feedback, never a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The card's surface: rounded, hairline-bordered, on the page color, with an optional fade
/// at the bottom edge when the content was clipped.
private final class PreviewCardView: NSView {

    /// How much of the card's bottom the clipped-content fade covers.
    private static let fadeHeight: CGFloat = 44

    private let fade = CAGradientLayer()
    private var hoverArea: NSTrackingArea?

    var showsBottomFade = false {
        didSet { if showsBottomFade != oldValue { needsDisplay = true } }
    }

    /// Whether the pointer is over the card — a hover presentation stays up while it is.
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = PeekPreviewPanel.cornerRadius
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
