import AppKit

/// The native reading pane: a scroll view hosting a `DocumentStackView`, plus the wiring for
/// links, heading tracking, and focus mode.
///
/// The pane used to host one document-wide `NSTextView`. Everything that made that hard —
/// widgets spliced in as attachments and measured before their views existed, card chrome
/// reconstructed out of paragraph spacing by custom layout fragments, a scroll height that had
/// to be grown to a fixed point because TextKit reports only what it has laid out — is gone with
/// it. What went with it too: selection across block boundaries, and `NSTextFinder`.
public final class NativeDocumentView: NSView {

    public weak var linkHandler: DocumentLinkHandler?

    /// Reports the current heading index (into `outline`) as the reader scrolls, so the outline
    /// can follow along.
    public var onHeadingChange: ((Int) -> Void)?

    /// Reports every heading whose section is on screen, by `outline` index.
    ///
    /// A spread routinely shows three or four sections at once, and marking one of them current
    /// hides the fact — the reader cannot tell whether the rest of the page belongs to that section
    /// or to the next three. The outline shows the group, with the current one stronger.
    public var onVisibleSectionsChange: ((Set<Int>) -> Void)?

    private var lastReportedVisible: Set<Int> = []

    let scrollView = NSScrollView()
    private let effectView = NSVisualEffectView()
    let stackView: DocumentStackView

    private(set) var built: BuiltDocument?
    private(set) var metrics: DocumentMetrics
    private var document: MarkdownDocument?

    public let sizeCache = BlockSizeCache()
    public let diagramLayouts = DiagramLayoutCache()
    public var pendingWorkCount = 0

    /// Component index → index into `built.headings`, so the outline can be tracked in the
    /// stack's own geometry rather than in character offsets.
    private var headingComponents: [(component: Int, heading: Int)] = []
    /// Component index → the heading whose section it belongs to, or -1 before the first heading.
    private var headingForComponent: [Int] = []
    private var lastReportedHeading = -1

    /// Substitutes a plain opaque background for the vibrancy material.
    ///
    /// `NSVisualEffectView` is rendered by the window server and draws nothing into an
    /// offscreen bitmap, so anything behind it captures as undefined pixels. Headless
    /// snapshots set this; on screen the material is used.
    public var usesOpaqueBackground = false {
        didSet {
            effectView.isHidden = usesOpaqueBackground
            needsDisplay = true
        }
    }

    public override var isOpaque: Bool { usesOpaqueBackground }

    public override func draw(_ dirtyRect: NSRect) {
        guard usesOpaqueBackground else { return }
        Ink.page.setFill()
        dirtyRect.fill()
    }

    public init(metrics: DocumentMetrics) {
        self.metrics = metrics
        self.stackView = DocumentStackView(metrics: metrics)
        super.init(frame: .zero)

        // Apple's documented material for scroll-view content. The default is the deprecated
        // `.appearanceBased`, so it must be set explicitly.
        effectView.material = .contentBackground
        effectView.blendingMode = .withinWindow
        effectView.state = .followsWindowActiveState
        effectView.translatesAutoresizingMaskIntoConstraints = false

        stackView.host = self
        stackView.linkDelegate = self

        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // The clip view paints its own background, which would sit opaquely over the pane's
        // material; the scroll view's own `drawsBackground` does not cover it.
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(effectView)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Scroll tracking drives both the outline and which components exist.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // Fires for the reader's own scrolling — trackpad, wheel, scroller — and never for a
        // programmatic scroll, which makes it the honest signal that they have taken over.
        NotificationCenter.default.addObserver(
            self, selector: #selector(readerStartedScrolling),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )

        // Accessibility display settings must be observed on NSWorkspace's own notification
        // center; registering on NotificationCenter.default fails silently.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Rendering

    public func render(document: MarkdownDocument, metrics: DocumentMetrics) {
        self.document = document
        self.metrics = metrics
        install(build(document: document), document: document)
    }

    private func build(document: MarkdownDocument) -> BuiltDocument {
        AttributedDocumentBuilder(document: document, metrics: metrics).build()
    }

    private func install(_ built: BuiltDocument, document: MarkdownDocument) {
        self.built = built
        sizeCache.removeAll()
        diagramLayouts.removeAll()

        // Headings are tracked by component from here on, so the mapping is resolved once
        // rather than per scroll event.
        headingComponents = built.headings.enumerated().compactMap { index, heading in
            guard let component = built.componentIndex(containing: heading.range.location)
            else { return nil }
            return (component: component, heading: index)
        }

        // Resolved once, so a scroll event costs a lookup rather than a search.
        headingForComponent = Array(repeating: -1, count: built.components.count)
        var cursor = 0
        for component in built.components.indices {
            while cursor < headingComponents.count,
                  headingComponents[cursor].component <= component {
                cursor += 1
            }
            headingForComponent[component] = cursor - 1 >= 0
                ? headingComponents[cursor - 1].heading : -1
        }

        lastReportedHeading = -1
        lastReportedVisible = []
        // A new document has no reading position yet; the old one's would name a component in a
        // different book.
        readingAnchor = nil
        stackView.setComponents(built.components, metrics: metrics)
        applyMeasure()
        stackView.layoutSubtreeIfNeeded()
        scrollToTop()
        reportViewport()
    }

    public func updateMetrics(_ metrics: DocumentMetrics) {
        self.metrics = metrics
        sizeCache.removeAll()
        diagramLayouts.removeAll()
        stackView.updateMetrics(metrics)
        applyMeasure()
    }

    // MARK: Viewport

    /// What the reader can actually see.
    ///
    /// The window draws its content under the titlebar and toolbar, and AppKit reserves that strip
    /// as a content inset — 52pt of it. The clip view's own bounds include that strip, so treating
    /// them as the viewport put everything 52pt too high: a heading navigated to sat *behind* the
    /// toolbar, and every probe read the document a toolbar's height ahead of the reader.
    private var readerViewport: NSRect {
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        var rect = clip.bounds
        rect.origin.y += insets.top
        rect.size.height = max(0, rect.height - insets.top - insets.bottom)
        return rect
    }

    /// How much of the viewport is usable, once the toolbar's strip is taken out.
    private var visibleHeight: CGFloat { readerViewport.height }

    /// The clip view's origin when the first line of the document meets the top of the page.
    ///
    /// Not zero. The window draws under its titlebar and toolbar, and AppKit reserves that strip
    /// as a content inset, which puts the topmost scroll position a toolbar's height *above* the
    /// document's own origin. The scroll view opens there by itself; clamping our own scrolls at
    /// zero is what took it away, and the first reflow restores the reading position — so every
    /// document opened 52pt down the page, its top margin behind the chrome and a strip of empty
    /// scroll left above the first line.
    private var topScrollOrigin: CGFloat { -scrollView.contentInsets.top }

    /// Parks the viewport at the very top of the document.
    ///
    /// For the second document and every one after it: the scroll view keeps the offset it had,
    /// so opening a file from a position halfway down a long one opened it halfway down. A
    /// document shorter than the viewport hid this — there the offset has nowhere to go but the
    /// top anyway.
    private func scrollToTop() {
        let clip = scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: topScrollOrigin))
        scrollView.reflectScrolledClipView(clip)
        stackView.populateVisible()
    }

    // MARK: Measure

    /// Sizes the stack to the pane, and decides how many columns it gets.
    private func applyMeasure() {
        let pane = bounds.width > 0 ? bounds.width : 800
        let columns = Self.columnCount(fitting: pane, metrics: metrics)
        stackView.columnCount = columns
        // A spread's columns are the reading measure; a single column may be narrower than the
        // measure on a small window, which is what `blockMeasure` clamps for.
        stackView.columnWidth = columns > 1 ? metrics.measure : metrics.blockMeasure(fitting: pane)
        // Columns are filled to what the reader can see, so a spread really is a screenful.
        stackView.spreadHeight = max(0, visibleHeight - DocumentMetrics.topPadding)
        if stackView.frame.width != pane {
            stackView.setFrameSize(NSSize(width: pane, height: stackView.frame.height))
        }
        stackView.needsLayout = true
        // Measure now, so the parking space below can be sized from real component positions.
        stackView.layoutSubtreeIfNeeded()
        updateTrailingParkingSpace()
    }

    /// Grows the space after the document so that *any* heading can be parked at the top.
    ///
    /// The last sections could not be: a scroll clamps at the end of the document, so the
    /// heading stayed mid-viewport and the reading-line probe reported whatever sat below it —
    /// clicking "4 Limitations" highlighted "References". The space needed is one viewport less
    /// whatever follows the last heading, so it is never more than a screenful and is nothing at
    /// all for a document that already ends with a long section.
    private func updateTrailingParkingSpace() {
        let viewport = visibleHeight
        // A document that already fits needs none: there is nothing to scroll, and adding space
        // would only invent it. This also keeps the headless snapshot renderer — which grows its
        // window to the document's height — from chasing its own tail. In a spread every
        // heading's spread can already be brought to the top, so there is nothing to add either.
        guard stackView.columnCount == 1, viewport > 0,
              stackView.contentHeight > viewport + 1,
              let last = headingComponents.last
        else {
            stackView.trailingParkingSpace = 0
            return
        }
        let after = max(0, stackView.contentHeight
                            - stackView.frame(ofComponent: last.component).minY)
        stackView.trailingParkingSpace = max(0, viewport - after - Self.navigationTopGap)
    }

    /// How far below the viewport's top edge navigation parks its target.
    private static let navigationTopGap: CGFloat = 12

    /// What the layout should settle on for the current pane, for tests that wait for a reflow.
    var settledLayoutForTests: (columns: Int, columnWidth: CGFloat) {
        let pane = bounds.width > 0 ? bounds.width : 800
        let columns = Self.columnCount(fitting: pane, metrics: metrics)
        return (columns, columns > 1 ? metrics.measure : metrics.blockMeasure(fitting: pane))
    }

    /// How many columns fit at the reading measure, within the reader's choice.
    ///
    /// A column is only ever the measure wide, so the count is simply how many measures plus
    /// gutters the pane holds inside its own margins — a squeezed column is worse than unused
    /// width, because the whole point is to stop wasting the width, not to cram narrower lines
    /// into it. The same rule bounds a pinned choice: three columns asked for on a pane that
    /// holds two gives two, not three thin ones. Nothing bounds it from above — a pane wide
    /// enough for six columns of full measure gets six.
    ///
    /// `layout` is defaulted from the settings rather than read inside, so a test can ask about
    /// a choice without writing to the process-wide defaults every other test shares.
    static func columnCount(fitting pane: CGFloat, metrics: DocumentMetrics,
                            layout: AppSettings.ColumnLayout
                                = AppSettings.shared.columnLayout) -> Int {
        let usable = pane - DocumentMetrics.minimumPadding * 2
        let step = metrics.measure + DocumentStackView.gutter
        let fits = Int((usable + DocumentStackView.gutter) / step)
        return max(1, min(layout.limit, fits))
    }

    public override func layout() {
        super.layout()
        // The stack follows the pane's width straight away, without re-measuring: its columns keep
        // their size and simply re-centre, which is what makes a sidebar toggle *glide*. Reflowing
        // on each frame of that animation was the lurch — every frame re-paginated the document
        // and moved everything twice.
        if stackView.frame.width != bounds.width, bounds.width > 0 {
            stackView.setFrameSize(NSSize(width: bounds.width, height: stackView.frame.height))
        }

        guard bounds.width != lastPaneWidth || bounds.height != lastPaneHeight else { return }
        let widthChanged = bounds.width != lastPaneWidth
        lastPaneWidth = bounds.width
        lastPaneHeight = bounds.height
        // A taller or shorter window keeps the pages it has. Height decides how tall a spread's
        // columns are filled, so following it re-paginated the document under the hand: dragging
        // the bottom edge pulled every page apart and pushed text between them, for a change the
        // reader made to the window rather than to the text. Only the measure — the width — is
        // worth re-flowing for; the pages take the new height at the next reflow, which is a font,
        // density, or width change away.
        guard widthChanged else {
            scheduleParkingSpaceUpdate()
            return
        }
        // Re-measuring inside `layout()` re-enters layout, and with heights cached per width the
        // two feed each other; the reflow is applied once things have settled.
        scheduleReflow()
    }

    /// Keeps the runway after the document a viewport long, without touching the pages.
    ///
    /// The other thing height is used for, and the one that does have to follow the window: the
    /// empty space after the last heading is what lets that heading be scrolled to the top of the
    /// viewport, and a window made taller needs more of it or the last few outline rows stop
    /// landing anywhere. Nothing that has text in it moves — the space is *after* the document.
    private func scheduleParkingSpaceUpdate() {
        guard !parkingSpaceUpdateQueued else { return }
        parkingSpaceUpdateQueued = true
        // Out of `layout()`: this resizes the stack, and resizing it inside layout re-enters it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            parkingSpaceUpdateQueued = false
            // The stack changing height is reported as a scroll, and the anchor must not be
            // re-read from it — that reading is the old position against the new geometry.
            isRestoringPosition = true
            defer { isRestoringPosition = false }
            updateTrailingParkingSpace()
        }
    }

    private var parkingSpaceUpdateQueued = false

    private var lastPaneWidth: CGFloat = 0
    private var lastPaneHeight: CGFloat = 0
    private var reflowWork: DispatchWorkItem?
    /// How long the pane waits for the size to stop changing before it reflows.
    ///
    /// Long enough to coalesce an animation — a sidebar toggle is a couple of hundred milliseconds
    /// of width changes at display rate — and short enough that a settled window reflows before
    /// the reader notices the columns are the wrong width.
    ///
    /// A test that drives an animation frame by frame widens it: a frame costs whatever the machine
    /// charges for it, and 50ms of grace that holds on a developer's desk is gone by the second
    /// frame on a CI runner, which reflows mid-animation and fails the test for the machine's
    /// speed rather than for the coalescing.
    static var reflowSettleDelay: TimeInterval = 0.05

    /// True while AppKit is resizing the pane live — the window's own edge, or a zoom.
    private var isLiveResizing = false
    /// Set when a size change arrived mid-navigation, and applied once the scroll lands.
    private var needsReflowAfterNavigation = false

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isLiveResizing = true
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizing = false
    }

    /// Whether a hand is on whatever is changing the pane's size.
    ///
    /// Nothing is re-measured under it. Reflowing means measuring every component, which is linear
    /// in the document, and a drag sends a size change per *point* — the text re-wrapping that
    /// often is a page churning under the reader's own hand, and on a long document it is the main
    /// thread doing it for the length of the drag. The layout in view follows the edge; the reflow
    /// lands once, when the edge is let go.
    ///
    /// Two kinds of drag resize the pane, and only one announces itself: AppKit sends live-resize
    /// notifications for the window's edge and nothing at all for the sidebar's divider, so the
    /// hand is asked about directly rather than waited on.
    ///
    /// Injected so a test can stand in for the hand; a divider drag does not survive being
    /// synthesized.
    static var isDragging: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    private func scheduleReflow() {
        // A reflow ends by putting the reader back where they were, which fights an animated
        // navigation for the viewport: the scroll gets cancelled halfway and lands back where it
        // started. The animation's completion handler asks for the reflow instead.
        if isNavigating {
            needsReflowAfterNavigation = true
            return
        }
        // Debounced: each size change replaces the pending reflow, so a drag or an animation
        // reflows once, when it stops, rather than on every step of it.
        reflowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Still under the hand: nothing is measured yet, and the release is watched for. A
            // divider drag ends with no notification to wait on, and a window drag that pauses
            // mid-way is just as much a hand on the edge.
            guard !isLiveResizing, !Self.isDragging() else { return scheduleReflow() }
            reflow()
        }
        reflowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reflowSettleDelay, execute: work)
    }

    /// Re-paginates for the bounds as they are now.
    ///
    /// For the snapshot renderer, which resizes its window between passes and captures what comes
    /// out: a height change no longer schedules a reflow of its own, and pagination at the height
    /// asked for is the whole point of `--render-png --height`.
    func reflowForSnapshot() { reflow() }

    private func reflow() {
        // A pending debounce is dropped: whatever asked for this reflow — the end of a drag, a
        // navigation landing, the snapshot renderer — has just measured the current width, and the
        // queued one would measure it again for nothing.
        reflowWork?.cancel()
        reflowWork = nil
        // Theirs if they have one; a fresh reading otherwise, for the first layout of a document.
        let anchor = readingAnchor ?? captureScrollAnchor()
        // For the whole reflow, not just the scroll at the end of it: measuring changes the
        // document's height, the viewport reports that as a scroll, and the anchor would be
        // overwritten with a reading of the new layout at the old offset — which is nobody's
        // position.
        isRestoringPosition = true
        defer { isRestoringPosition = false }
        // The size cache is keyed by (component, width), so entries for other widths are harmless
        // — and in a spread the column is the reading measure whatever the pane's width, so a
        // resize usually changes no height at all. Clearing it threw away a book's worth of
        // measurements to re-measure them identically.
        applyMeasure()
        stackView.layoutSubtreeIfNeeded()
        // A heading the reader navigated to outranks a captured offset: it is where they asked to
        // be, and the reflow may have moved everything else.
        if let target = navigationTarget,
           let component = headingComponents.first(where: { $0.heading == target })?.component {
            scroll(toComponent: component, animated: false)
        } else {
            restore(anchor)
        }
    }

    // MARK: Navigation

    /// Scrolls a heading to the top of the viewport.
    public func scroll(toAnchor anchor: String) {
        guard let built, let range = built.anchors[anchor] else { return }
        scroll(toCharacterIndex: range.location)
    }

    public func scroll(toCharacterIndex index: Int, animated: Bool = true) {
        guard let built, let component = built.componentIndex(containing: index) else { return }
        scroll(toComponent: component, animated: animated)
    }

    public func scroll(toComponent index: Int, animated: Bool = true) {
        stackView.layoutSubtreeIfNeeded()
        // `scrollRangeToVisible`'s "just barely visible" alignment is wrong for navigation — the
        // reader expects the heading at the top. In a spread that means the top of the spread the
        // heading is on, not the heading's own y: aligning mid-column would cut every column.
        let target = max(0, stackView.alignmentY(forComponent: index) - Self.navigationTopGap)
        // Pinned whether or not the scroll is animated: with Reduce Motion on, a click on a short
        // section would otherwise land and immediately report the section *below* it.
        reportDestinationHeading(forComponent: index)
        // Only for a navigation the reader asked for. A restore after a reflow puts them back
        // where they already were, and has nothing to point out.
        if animated { pendingFlash = index }
        // Asking to be somewhere is putting yourself there: a later layout change should bring
        // them back here, not to wherever they were before the click.
        if !isRestoringPosition {
            readingAnchor = ScrollAnchor(component: index, offset: -Self.navigationTopGap)
        }
        scroll(toY: target, animated: animated)
    }

    /// How long a navigation scroll takes. Long enough to see where the document went, short
    /// enough that it never feels like waiting.
    private static let navigationScrollDuration: TimeInterval = 0.3

    /// True while an animated navigation is in flight.
    private var isNavigating = false

    /// The component to flash once the viewport has arrived.
    ///
    /// Held until then rather than flashed at the click: during the scroll the component is still
    /// somewhere else, and a glow the reader never sees is no cue at all.
    private var pendingFlash: Int?

    /// Whether navigation eases the viewport. Tests turn it off so their timing does not depend
    /// on a 300ms animation completing.
    var animatesNavigation = true

    /// Eases the viewport to `y`, or jumps there.
    ///
    /// A jump loses the reader — after clicking an outline row there is no way to tell whether
    /// the document moved half a screen or ten. The clip view's `boundsOrigin` is animatable, so
    /// the ease needs no timer of its own; unlike `scroll(to:)` it does *not* clamp, so the
    /// destination is clamped here or the viewport can be animated past the end of the document.
    /// Scrolls to the top of a page, for the snapshot renderer.
    func showPageForSnapshot(_ page: Int) {
        let top = stackView.spreadFrame(at: page).minY
        scrollView.contentView.setBoundsOrigin(
            NSPoint(x: 0, y: max(topScrollOrigin, top - scrollView.contentInsets.top))
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        stackView.populateVisible()
    }

    private func scroll(toY y: CGFloat, animated: Bool) {
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let minimum = topScrollOrigin
        let maximum = max(minimum, stackView.frame.height + insets.bottom - clip.bounds.height)
        // `y` is where the document should meet the *visible* top, so the toolbar's strip comes
        // off it: scrolling to the raw value parked the target behind the toolbar.
        let destination = NSPoint(x: 0, y: min(max(minimum, y - insets.top), maximum))
        // Clamped, and in the same visible terms the probes use, so arrival is judged against an
        // offset that is actually reachable.
        if navigationTarget != nil {
            navigationOffset = destination.y + scrollView.contentInsets.top
        }

        guard animated, animatesNavigation,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(destination.y - clip.bounds.origin.y) > 2
        else {
            clip.scroll(to: destination)
            scrollView.reflectScrolledClipView(clip)
            stackView.populateVisible()
            reportViewport()
            flushPendingFlash()
            return
        }

        isNavigating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.navigationScrollDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(destination)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isNavigating = false
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.stackView.populateVisible()
            self.reportViewport()
            self.flushPendingFlash()
            if self.needsReflowAfterNavigation {
                self.needsReflowAfterNavigation = false
                self.scheduleReflow()
            }
        })
    }

    /// A semantic scroll position that survives a rebuild.
    ///
    /// A raw pixel offset is meaningless exactly when it would be used: the only things that
    /// trigger a rebuild are font, width, and density changes, all of which reflow the document.
    public struct ScrollAnchor {
        let component: Int
        /// Where the viewport's top edge sat relative to that component's top, in points.
        ///
        /// Signed on purpose: at the top of the document the edge is *above* the first
        /// component, by the container's top padding. Clamping that to zero scrolled the
        /// document down by the padding every time a width change restored the position.
        let offset: CGFloat
    }

    public func captureScrollAnchor() -> ScrollAnchor {
        let top = readerViewport.minY
        guard let component = stackView.componentIndex(atY: top) else {
            return ScrollAnchor(component: 0, offset: 0)
        }
        // Measured against the same y navigation aligns on, so a position captured in a spread
        // restores to that spread rather than to the middle of a column.
        return ScrollAnchor(component: component,
                            offset: top - stackView.alignmentY(forComponent: component))
    }

    public func restore(_ anchor: ScrollAnchor) {
        stackView.layoutSubtreeIfNeeded()
        scroll(toY: stackView.alignmentY(forComponent: anchor.component) + anchor.offset,
               animated: false)
    }

    // MARK: Heading tracking

    private func flushPendingFlash() {
        guard let index = pendingFlash else { return }
        pendingFlash = nil
        stackView.flash(component: index)
    }

    @objc private func readerStartedScrolling() {
        navigationTarget = nil
        navigationOffset = nil
        navigationArrived = false
        // They have moved on; a glow arriving now would point at nothing.
        pendingFlash = nil
        // An animated scroll that is still in flight would drag the viewport back out from under
        // them for the rest of its duration. A zero-length animation to where the viewport
        // actually is replaces the running one and leaves it there.
        guard isNavigating else { return }
        isNavigating = false
        let clip = scrollView.contentView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            clip.animator().setBoundsOrigin(clip.bounds.origin)
        }
    }

    @objc private func viewportChanged() {
        // The scrollers do not follow an animated `boundsOrigin` on their own.
        if isNavigating { scrollView.reflectScrolledClipView(scrollView.contentView) }
        stackView.populateVisible()
        rememberReadingPosition()
        reportViewport()
    }

    /// Where the reader put themselves, kept so a layout change can put them back.
    ///
    /// Captured from their movement and never from ours. A restore is a scroll like any other, and
    /// letting it write here is what made the position drift: in a spread the anchor can only name
    /// the top of a page, so restoring quantised it to a page start, and the next layout change
    /// captured *that* — one column to two and back returned the reader to somewhere they had
    /// never been, a little earlier every round trip. Anchored to their own last position, the same
    /// trip is exact however many times it is made.
    private var readingAnchor: ScrollAnchor?
    /// Set while the pane is scrolling itself, so the anchor above stays the reader's.
    private var isRestoringPosition = false

    private func rememberReadingPosition() {
        guard !isRestoringPosition, !isNavigating, built != nil else { return }
        readingAnchor = captureScrollAnchor()
    }

    /// How far below the viewport's top edge the "currently reading" probe sits when the reader
    /// is at the top of the document.
    private static let readingLineInset: CGFloat = 80

    /// The heading an explicit navigation parked at the top of the viewport.
    ///
    /// It sticks — overriding the probe — for as long as it is still parked there. Navigation
    /// puts its target 12pt below the top edge while the probe sits at 80, so in a section
    /// shorter than that the probe reports the *next* heading and clicking "2 Method" highlighted
    /// "2.1". Pinning the target is what makes the click authoritative; a position-only band did
    /// this before and had to be dropped, because near the top of the viewport a band
    /// legitimately holds an *earlier* heading than the probe, and preferring it made the outline
    /// flash backwards mid-scroll.
    private var navigationTarget: Int?
    /// The scroll offset that navigation asked for.
    ///
    /// Arrival is judged against this rather than against where the heading ended up: near the end
    /// of a document the scroll clamps, so the heading never reaches the top of the viewport, and a
    /// pin waiting for it to get there was never released — the outline stayed stuck on the clicked
    /// section for every scroll that is not a trackpad gesture, keyboard paging included.
    private var navigationOffset: CGFloat?
    /// Whether the viewport has actually reached the pinned target yet.
    ///
    /// The pin cannot be released just because the viewport is not there: an animated scroll's
    /// completion handler can run before the bounds have finished moving, and releasing the pin on
    /// that first mismatch reported the *previous* section — click "1.1 Motivation", get
    /// "1 Introduction". So the pin holds unconditionally until the target arrives once; only then
    /// does scrolling away release it.
    private var navigationArrived = false

    /// Where the probe sat last time, so tracking knows which way the reader is going.
    private var lastProbeOffset: CGFloat = 0

    private func reportViewport() {
        // Which way the reader is going, recorded before any early return: a pinned navigation
        // returns above the tracking code, and leaving the last offset stale there made the next
        // scroll *upwards* look like no movement at all — which the guard below reads as forward,
        // and forward never moves the outline back.
        let offset = readerViewport.minY
        let isScrollingDown = offset > lastProbeOffset
        lastProbeOffset = offset

        guard let built, !built.headings.isEmpty else { return }
        // What is on screen is a fact about the viewport, so it is reported whatever the tracking
        // logic decides — including while a navigation is pinned. Reporting it at the end of the
        // tracking path meant a click left the group showing the page the reader had *left*.
        reportVisibleSections(in: built)

        // Mid-flight the viewport sweeps through every section between here and the destination;
        // reporting those would flicker the outline on the way past.
        guard !isNavigating else { return }

        if let target = navigationTarget {
            let offset = readerViewport.minY
            if let destination = navigationOffset, abs(offset - destination) <= 4 {
                navigationArrived = true
                report(heading: target, in: built)
                return
            }
            if !navigationArrived {
                // Still on its way there.
                report(heading: target, in: built)
                return
            }
            // The reader has moved on from the click; the probe takes over again.
            navigationTarget = nil
            navigationOffset = nil
        }
        guard var heading = headingAtReadingLine() else { return }
        // Scrolling forward never moves the outline backwards. Navigation aligns on a spread, so
        // the probe can start the next report *behind* the heading that was clicked — and an
        // outline that jumps back a section as the reader scrolls on reads as a glitch.
        if isScrollingDown, lastReportedHeading >= 0 {
            heading = max(heading, lastReportedHeading)
        }
        report(heading: heading, in: built)
    }

    private func headingAtReadingLine() -> Int? {
        let clip = readerViewport
        // Fixed just below the top edge, so the outline agrees with what the reader has actually
        // reached. It used to slide with progress through the whole document, which put it
        // hundreds of points ahead of the viewport and reported sections before they arrived.
        var probe = clip.minY + Self.readingLineInset
        // Across the final screenful it does slide, to the bottom edge: down there every
        // remaining section sits below a fixed probe, so none of them could ever become current
        // — which is what left the outline pointing several sections back at the end.
        let remaining = max(0, stackView.frame.height - clip.height) - clip.minY
        if clip.height > 0, remaining < clip.height {
            let progress = min(1, max(0, 1 - remaining / clip.height))
            probe += (clip.height - Self.readingLineInset) * progress
        }
        guard let component = stackView.componentIndex(atY: probe) else { return nil }
        // Above the first heading — inside the frontmatter card, say — the first section is
        // still the one being read. Reporting nothing there left a stale highlight behind.
        return headingComponents.last { $0.component <= component }?.heading ?? 0
    }

    private func reportDestinationHeading(forComponent index: Int) {
        guard let built,
              let heading = headingComponents.last(where: { $0.component <= index })?.heading
        else { return }
        navigationTarget = heading
        navigationArrived = false
        report(heading: heading, in: built)
    }

    /// Every section with any of its content on screen.
    ///
    /// A section is visible when *any* component belonging to it is. Testing the span from its
    /// heading to the next one instead — a union of the two frames — is wrong once the document is
    /// paginated: those frames sit on different pages, and the rectangle between them covers
    /// everything in between, on screen or not. That reported sections that were nowhere in sight
    /// and skipped ones that were.
    private func reportVisibleSections(in built: BuiltDocument) {
        guard onVisibleSectionsChange != nil else { return }
        var visible: Set<Int> = []
        for component in stackView.components(intersecting: readerViewport) {
            let heading = headingForComponent.indices.contains(component)
                ? headingForComponent[component] : -1
            guard heading >= 0, built.headings.indices.contains(heading) else { continue }
            visible.insert(built.headings[heading].outlineIndex)
        }

        guard visible != lastReportedVisible else { return }
        lastReportedVisible = visible
        onVisibleSectionsChange?(visible)
    }

    private func report(heading: Int, in built: BuiltDocument) {
        guard heading != lastReportedHeading, built.headings.indices.contains(heading)
        else { return }
        lastReportedHeading = heading
        onHeadingChange?(built.headings[heading].outlineIndex)
    }

    @objc private func accessibilityDisplayChanged() {
        // Hairline and tag colors bake the contrast setting into attribute values, so they have
        // to be re-derived.
        needsDisplay = true
        if let document { render(document: document, metrics: metrics) }
    }
}

// MARK: - Links

extension NativeDocumentView: ComponentLinkDelegate {
    public func component(_ view: NSView, didClickLink destination: String) {
        route(destination)
    }

    fileprivate func route(_ destination: String) {
        guard let document else { return }
        let base = document.url.deletingLastPathComponent()
        switch LinkRouter.resolve(destination, relativeTo: base) {
        case .external(let url), .file(let url):
            NSWorkspace.shared.open(url)
        case .fragment(let anchor):
            scroll(toAnchor: anchor)
        case .markdown(let url, let fragment):
            linkHandler?.documentView(self, openMarkdown: url, fragment: fragment)
        case .missing:
            // The web view silently 404'd these; a beep is the whole feedback now that the
            // status bar is gone.
            NSSound.beep()
        }
    }
}

// MARK: - Block host

extension NativeDocumentView: BlockHost {
    public var blockMetrics: DocumentMetrics { metrics }

    public func blockRequestsOpen(_ destination: String) {
        route(destination)
    }

    public func blockRequestsCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

public protocol DocumentLinkHandler: AnyObject {
    func documentView(_ view: NativeDocumentView, openMarkdown url: URL, fragment: String?)
}
