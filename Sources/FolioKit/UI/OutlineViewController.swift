import AppKit

/// The document's heading tree. Selecting a row scrolls the reading pane to that heading.
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var onSelect: ((String) -> Void)?
    /// Pull-based provider for the peek card's content, so a card can never show a stale
    /// section after the document re-renders.
    var onPreviewContent: ((Int) -> SectionPreview?)?

    private let preview = OutlinePreviewController()
    private var entries: [OutlineEntry] = []
    private var highlightedIndex = 0
    /// Every section on screen. The current one is in here too, and outranks the group marking.
    private var visibleIndices: Set<Int> = []
    private var indicatorsScheduled = false


    private let tableView = OutlineTableView()
    private let scrollView = NSScrollView()

    override func loadView() {
        view = NSView()

        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 26
        // The system source-list selection is a fully saturated accent pill, and the current
        // row's label is accent-coloured — so the highlighted row came out blue on blue with the
        // text all but gone. Rows paint their own soft pill instead: see `OutlineRowView`.
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self
        // The table owns its own press tracking (click vs press-to-peek), so there is no
        // target/action pair — a quick click arrives as `onRowClick`.
        tableView.onRowClick = { [weak self] row in self?.rowClicked(row) }
        tableView.onPreviewRow = { [weak self] row in self?.previewRow(row) }
        preview.onDismissRequest = { [weak self] in self?.cancelPreview() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // `drawsBackground = false` on the scroll view alone is not enough: the clip view paints
        // its own background, and a legacy scroller reserves and paints a permanent track. Both
        // sit on top of the sidebar's vibrancy as an opaque strip.
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func clear() {
        cancelPreview()
        entries = []
        highlightedIndex = 0
        tableView.reloadData()
    }

    func update(document: MarkdownDocument) {
        cancelPreview()
        entries = document.outline
        highlightedIndex = 0
        tableView.reloadData()
    }

    /// Ends any press-to-peek in flight: a document swap or a settings reflow invalidates
    /// both the card's content and the geometry it was anchored to.
    func cancelPreview() {
        tableView.cancelPress()
        preview.hide()
        tableView.hoverSuppressed = false
    }

    /// Marks every section that is on screen.
    ///
    /// A spread shows three or four at once, so one highlighted row misrepresents the page: the
    /// group says how far it reaches, and the pill inside it says where the reader is.
    func markVisible(_ indices: Set<Int>) {
        guard indices != visibleIndices else { return }
        visibleIndices = indices
        scheduleIndicators()
    }

    /// Moves the block on the next turn.
    ///
    /// Coalesced because the current heading and the visible group arrive as two callbacks from
    /// the reading pane, and a block that restarts its animation twice per scroll event stutters.
    private func scheduleIndicators() {
        guard !indicatorsScheduled else { return }
        indicatorsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.indicatorsScheduled = false
            self.tableView.setGroup(self.visibleIndices)
        }
    }

    /// Notes which section is being read.
    ///
    /// Nothing is drawn for it: the block over the sections on screen is the outline's whole state,
    /// and a second marking inside it competed with the block for the reader's attention without
    /// telling them anything the block did not. The index is still worth having — it keeps the row
    /// on screen on a long outline.
    func highlight(index: Int) {
        guard index != highlightedIndex, index >= 0, index < entries.count else { return }
        highlightedIndex = index
        tableView.scrollRowToVisible(index)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    /// The outline never holds a system selection.
    ///
    /// The pill is the only state it shows, and a selected row is a second one waiting to
    /// surface: `selectionHighlightStyle = .none` suppresses the fill, but AppKit still owns how
    /// a selected source-list row is styled, and that varies with appearance and accessibility
    /// settings. Refusing selection outright leaves nothing to disagree with the pill. Clicks
    /// still arrive — `rowClicked` reads `clickedRow`, not the selection.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = OutlineRowView()
        // A row scrolled in under a stationary pointer is hovered the moment it exists.
        rowView.isHovered = row == self.tableView.hoveredRow
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: entry.title)
        tf.lineBreakMode = .byTruncatingTail
        // Hierarchy is carried by weight and indentation, not by fading rows toward the
        // background: at level 4 the old `tertiaryLabelColor` measured 2.3:1 against a 4.5:1
        // floor, which is why deeper headings were unreadable.
        tf.font = NSFont.systemFont(
            ofSize: 12,
            weight: NSFont.Weight(rawValue: OutlineRowView.baseWeight(forLevel: entry.level))
        )
        tf.textColor = OutlineRowView.baseColor(forLevel: entry.level)

        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        let indent = CGFloat(max(0, entry.level - 1)) * 12
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8 + indent),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func rowClicked(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        // Move the highlight on the click rather than waiting for the reading pane to scroll and
        // report back: the pill should follow the pointer immediately.
        highlight(index: row)
        onSelect?(entries[row].anchor)
    }

    /// Shows the peek card for a row, or hides it while the press scrubs off the rows or onto
    /// a section with nothing under its heading. Hover goes quiet with the card up — the
    /// sidebar is the dimmed layer then, and nothing dimmed should answer the pointer.
    private func previewRow(_ row: Int) {
        defer { tableView.hoverSuppressed = preview.isShown }
        guard row >= 0, row < entries.count, let section = onPreviewContent?(row) else {
            preview.hide()
            return
        }
        preview.show(section, title: entries[row].title,
                     anchoredToRow: row, in: tableView)
    }
}

/// The outline's table, which owns where the pointer is.
///
/// Hover is computed from one mouse position and pushed to the row views, rather than each row
/// tracking its own — see `OutlineRowView.isHovered`.
final class OutlineTableView: NSTableView {

    /// How long a press has to hold still before it becomes a peek instead of a click. A
    /// `static var` so tests can zero it.
    static var holdDelay: TimeInterval = 0.35

    /// A quick click, released before the hold threshold on the row it pressed.
    var onRowClick: ((Int) -> Void)?
    /// The peek trigger fired (hold elapsed or force click) or the held pointer scrubbed to
    /// another row; -1 means the pointer is off the rows and the card should hide.
    var onPreviewRow: ((Int) -> Void)?

    private let press = OutlinePressPreviewState()
    private var holdTimer: Timer?
    /// The row under the pressed pointer, maintained from the press's own event stream — the
    /// pointer cannot move while the button is down without a `mouseDragged`, so this is always
    /// current when the hold timer or a force click needs it, and it keeps the gesture
    /// deterministic under synthesized events in tests.
    private var pressPointerRow = -1

    /// While the peek card is up, the sidebar is the dimmed layer under it: pointer feedback
    /// there would claim an interactivity the backdrop has taken away, so hover is silenced
    /// wholesale rather than filtered event by event.
    var hoverSuppressed = false {
        didSet {
            guard hoverSuppressed != oldValue else { return }
            if hoverSuppressed { setHovered(row: -1) } else { refreshHover() }
        }
    }

    /// The row under the pointer, or -1.
    private(set) var hoveredRow = -1

    /// One block spanning the sections on screen, rather than a marking per row.
    ///
    /// A tint on each row read as a list of selections; the page is one thing, so it gets one
    /// shape. It moves and resizes with an animation, because a block that jumps between two
    /// positions is hard to follow — and following it is the entire point.
    private let group = OutlineIndicatorView()
    private(set) var groupRows: ClosedRange<Int>?

    private var hoverArea: NSTrackingArea?

    /// The durations the last move and the last fade were given, so a test can tell an animation
    /// from a jump.
    private(set) var lastMoveDuration: TimeInterval = 0
    private(set) var lastFadeDuration: TimeInterval = 0

    /// Slides the block over the sections on screen, fading it in and out as it comes and goes.
    ///
    /// The move and the fade are two animations, because they are not the same event. A block
    /// travelling between sections has a frame to interpolate; one arriving or leaving has none —
    /// there is nowhere to come from — and sharing the move's duration with it meant both ends of
    /// the block's life were the one part that popped.
    func setGroup(_ rows: Set<Int>, completion: @escaping () -> Void = {}) {
        if group.superview == nil {
            group.alphaValue = 0
            addSubview(group, positioned: .below, relativeTo: nil)
        }
        let box = self.box(spanning: rows)
        groupRows = box == nil ? nil : range(of: rows)

        // A block that is appearing is positioned before the animation starts: inside it, setting
        // a frame animates from wherever the view happened to be — the origin, for a fresh one.
        let appearing = group.alphaValue < 0.5
        if appearing, let box { group.frame = box }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = appearing || box == nil || box == self.group.frame
                ? 0
                : OutlineIndicatorView.moveDuration
            lastMoveDuration = context.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            if let box { self.group.animator().frame = box }
        }, completionHandler: completion)

        NSAnimationContext.runAnimationGroup { context in
            let target: CGFloat = box == nil ? 0 : 1
            context.duration = self.group.alphaValue == target
                ? 0
                : OutlineIndicatorView.fadeDuration
            lastFadeDuration = context.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.group.animator().alphaValue = target
        }
    }

    private func range(of rows: Set<Int>) -> ClosedRange<Int>? {
        guard let low = rows.min(), let high = rows.max(), numberOfRows > 0 else { return nil }
        return max(0, low)...min(numberOfRows - 1, high)
    }

    private func box(spanning rows: Set<Int>) -> NSRect? {
        guard let range = range(of: rows) else { return nil }
        return rect(ofRow: range.lowerBound).union(rect(ofRow: range.upperBound))
            .insetBy(dx: OutlineIndicatorView.inset.width, dy: OutlineIndicatorView.inset.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.mouseMoved` as well as enter/exit: the pointer can cross from one row to the next
        // without ever leaving the table.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { setHovered(row: -1) }

    // MARK: Press-to-peek

    /// Registers for deep-click events; on hardware without pressure they simply never arrive
    /// and the hold timer is the only path to a peek.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
    }

    /// Deliberately not calling super: NSTableView's own `mouseDown` runs a tracking loop and
    /// fires the action on mouse-up, which could not be swallowed after a peek. Selection and
    /// editing are disabled on this table, so nothing else is lost — a quick click is re-created
    /// in `mouseUp`, and dragged/up events arrive as ordinary events while the button is down.
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        press.pressBegan(row: row)
        pressPointerRow = row
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.perform(self.press.holdFired(pointerRow: self.pressPointerRow))
        }
        RunLoop.current.add(timer, forMode: .common)
        holdTimer = timer
    }

    override func mouseDragged(with event: NSEvent) {
        guard press.pressedRow >= 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        pressPointerRow = visibleRect.contains(point) ? row(at: point) : -1
        perform(press.pointerMoved(toRow: pressPointerRow))
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        perform(press.released(
            pointerRow: row(at: convert(event.locationInWindow, from: nil))
        ))
        pressPointerRow = -1
    }

    /// A force click is the same peek as the hold, sooner — with the system's own haptic.
    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        guard event.stage >= 2 else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        perform(press.forceClicked(pointerRow: pressPointerRow))
    }

    /// Ends a press in flight without emitting anything; the owner hides the card itself.
    func cancelPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        press.cancel()
        pressPointerRow = -1
    }

    private func perform(_ effect: OutlinePressPreviewState.Effect) {
        switch effect {
        case .none:
            break
        case .show(let row), .update(let row):
            onPreviewRow?(row)
        case .pin:
            // The release keeps the card up; from here its backdrop owns dismissal.
            break
        case .click(let row):
            onRowClick?(row)
        }
    }

    override func layout() {
        super.layout()
        resizeGroup()
        // Rows move under a stationary pointer while scrolling, and no mouse event is sent for
        // that: the hovered row has to be re-derived from where the pointer already is.
        refreshHover()
    }

    /// Keeps the block the width of the table.
    ///
    /// Its frame is only otherwise set when it moves, so a sidebar dragged wider or narrower left
    /// the block at whatever width the sidebar had when the page last changed — a block that
    /// stopped short of the rows it was meant to be marking.
    ///
    /// Never animated: this is the sidebar being resized, not the block moving, and the two look
    /// nothing alike. The explicit zero duration is because a collapsing sidebar animates its
    /// layout, and an implicit animation would take this frame with it.
    private func resizeGroup() {
        guard group.superview != nil, let rows = groupRows,
              let box = box(spanning: Set(rows)), group.frame != box
        else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            group.frame = box
        }
    }

    private func updateHover(with event: NSEvent) {
        guard !hoverSuppressed else { return }
        setHovered(row: row(at: convert(event.locationInWindow, from: nil)))
    }

    /// Re-derives the hovered row from the pointer's current position.
    func refreshHover() {
        guard let window, !hoverSuppressed, window.isKeyWindow || window.isMainWindow else {
            setHovered(row: -1)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(row: visibleRect.contains(point) ? row(at: point) : -1)
    }

    private func setHovered(row: Int) {
        hoveredRow = row
        // Every live row view is synced on every update, not just the two that changed, so a
        // stray hovered row cannot survive anywhere. The row view only redraws when its own
        // value actually changes, so this costs nothing.
        enumerateAvailableRowViews { view, index in
            (view as? OutlineRowView)?.isHovered = index == row
        }
    }
}

/// One outline row's background: the pill that follows the pointer.
///
/// Nothing else is drawn per row. The block over the sections on screen is the outline's state, and
/// a second marking for the row being read sat inside that block competing with it — two shapes
/// saying almost the same thing, one of which the reader had to work out.
final class OutlineRowView: NSTableRowView {

    private static let cornerRadius: CGFloat = 8
    /// Keeps the pill clear of the sidebar's edges, matching the block.
    private static let inset = NSSize(width: 6, height: 1)
    /// Strength of the pointer's own marking. Stronger than the block behind it, because it
    /// answers a question the reader is asking right now.
    static let hoverTint: CGFloat = 0.10

    /// Set by `OutlineTableView`, which owns the pointer's position for the whole table.
    ///
    /// It used to be tracked per row, with a tracking area on each: rows are recycled and scrolled
    /// under the pointer, `mouseExited` does not always arrive for one that is being reused, and the
    /// state was left set on several rows at once — three hovered rows on screen together. Derived
    /// state cannot leak that way: exactly one row can be under the pointer, so exactly one place
    /// computes it.
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    /// Resting weight and colour for a heading level. Hierarchy is carried by weight and
    /// indentation rather than by fading rows toward the background: at level 4 the old
    /// `tertiaryLabelColor` measured 2.3:1 against a 4.5:1 floor.
    static func baseWeight(forLevel level: Int) -> CGFloat {
        switch level {
        case 1: return NSFont.Weight.semibold.rawValue
        case 2: return NSFont.Weight.medium.rawValue
        default: return NSFont.Weight.regular.rawValue
        }
    }

    static func baseColor(forLevel level: Int) -> NSColor {
        level <= 2 ? Ink.body : Ink.secondary
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered else { return }
        let pill = bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height)
        Ink.accent.withAlphaComponent(Self.hoverTint).setFill()
        NSBezierPath(roundedRect: pill, xRadius: Self.cornerRadius,
                     yRadius: Self.cornerRadius).fill()
    }
}

/// One block behind the rows whose sections are on the page.
///
/// A view rather than per-row drawing, so it can *move*: tinting each row instead made the page
/// read as a list of selections, and the marking jumped from row to row as the reader scrolled.
/// One shape that slides is followable; several that blink are not.
final class OutlineIndicatorView: NSView {

    /// Keeps the block clear of the sidebar's edges.
    static let inset = NSSize(width: 6, height: 0)
    /// Long enough to follow, short enough not to lag behind a scroll.
    static var moveDuration: TimeInterval = 0.12
    /// Coming and going is a softer event than moving, so it takes a touch longer.
    static var fadeDuration: TimeInterval = 0.18
    /// Light enough to sit under a row's hover pill without competing with it.
    static let tint: CGFloat = 0.07
    static let cornerRadius: CGFloat = 8

    /// Drawn by its layer rather than by `draw(_:)`.
    ///
    /// Not a detail: a block that draws itself has its frame animated by AppKit's own timer, and
    /// that timer does not run while the reading pane is being scrolled — the scroll puts the run
    /// loop in event-tracking mode. So the block arrived at its new rows in one jump, animated
    /// everywhere except during the scroll that moved it. Core Animation runs the same move on the
    /// render server, where a tracking loop cannot starve it.
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    /// Feedback, never a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Geometry the layer owns, so a move is a layer animation rather than a redraw per frame.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Ink.accent.withAlphaComponent(Self.tint).cgColor
            // A hairline edge so the page reads as one object, whatever sits on it.
            layer.borderColor = Ink.accent.withAlphaComponent(Self.tint * 1.6).cgColor
        }
        layer.borderWidth = 1
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
