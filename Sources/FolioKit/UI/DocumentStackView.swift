import AppKit

/// The reading surface: one view per component, stacked.
///
/// Replaces a single document-wide `NSTextView`. The stack owns the geometry — it measures every
/// component up front, positions them from those measurements, and populates only the ones near
/// the viewport — which is what lets a widget be an ordinary view with an ordinary `layout()`
/// instead of a text attachment measured before it exists.
///
/// Two things it deliberately does *not* do, both inherited from the text engine it replaced:
/// selection across component boundaries, and `NSTextFinder`.
public final class DocumentStackView: NSView {

    public weak var host: BlockHost?
    public weak var linkDelegate: ComponentLinkDelegate?
    /// Set only by surfaces that can peek — the reading pane. The peek card's own stack leaves
    /// it nil, so a link inside a card can never open a card of its own.
    public weak var linkPeekDelegate: ComponentLinkPeekDelegate?

    private(set) var components: [DocumentComponent] = []
    private var metrics: DocumentMetrics

    /// The reading column's width. Components are laid out this wide and centred in the pane,
    /// which is what keeps one left edge for prose and cards alike.
    public var columnWidth: CGFloat = 0 {
        didSet { if columnWidth != oldValue { invalidateMeasurement() } }
    }

    /// How many columns the document is laid out in.
    ///
    /// More than one turns the page into a spread: components fill the first column, then the
    /// next, then the first column of the spread below. That is pagination — the only way several
    /// pages fit one screen — but the spreads stack vertically, so scrolling is still scrolling
    /// and every position, from an outline click to a restored anchor, keeps working. Nothing
    /// here is written for two in particular; the count comes from the pane's width.
    public var columnCount: Int = 1 {
        didSet { if columnCount != oldValue { invalidateMeasurement() } }
    }

    /// Gutter between columns of a spread.
    public static let gutter: CGFloat = 40

    /// The height a spread's columns are filled to, normally the viewport's.
    ///
    /// A component taller than this is split only where the content has a seam of its own — a
    /// table at its rows, a list at its items. Anything else, prose and code cards included,
    /// would need line-level pagination to break; until that exists it takes a page of its own
    /// instead, which is better than being sliced mid-line.
    public var spreadHeight: CGFloat = 0 {
        didSet { if spreadHeight != oldValue { invalidateMeasurement() } }
    }

    /// The page's breathing room above and below the content.
    ///
    /// The reading pane keeps the defaults. A smaller surface reusing this engine — the
    /// sidebar's peek card — supplies its own chrome and sets these to zero, rather than
    /// inheriting a page's worth of empty space it has no page for.
    public var contentInsets: (top: CGFloat, bottom: CGFloat) =
        (DocumentMetrics.topPadding, DocumentMetrics.bottomPadding) {
        didSet {
            if contentInsets != oldValue { invalidateMeasurement() }
        }
    }

    private func invalidateMeasurement() {
        measuredWidth = 0
        needsLayout = true
    }

    /// Where every component sits, in the stack's own coordinates, and which spread it belongs
    /// to. Recomputed only when the width, the column count, or the document changes, so
    /// scrolling never re-measures.
    /// One entry per *placement*, not per component: a long table is paginated across pages, so
    /// a component can occupy several slots. Everything positional is keyed this way, and the
    /// component-keyed API maps through `firstPlacement`.
    private var frames: [CGRect] = []
    private var spreadOfPlacement: [Int] = []
    private var columnOfPlacement: [Int] = []
    /// Placements too tall for a column, which take a page of their own across both of them.
    private var spansSpread: [Bool] = []
    private var componentOfPlacement: [Int] = []
    /// For a page of a split table or list: which of the rows — or list items — it holds, and
    /// for a table the column widths the whole table measured to, so every page of it lines up.
    private var rowsOfPlacement: [Range<Int>?] = []
    private var tableColumnsOfPlacement: [[CGFloat]?] = []
    private var firstPlacement: [Int] = []
    /// Which section each placement belongs to, and where that section carries on — if it does.
    private var sectionOfPlacement: [Int] = []
    private var continuationOfPlacement: [Continuation?] = []

    /// Where a section picks up again, when a page could not hold all of it.
    ///
    /// Only page breaks are recorded. Every column of a page is on screen together, so a section
    /// crossing between them needs no telling; a section crossing to the *next* page does.
    public enum Continuation {
        case nextPage
    }

    private func resetPlacements() {
        frames = []
        spreadOfPlacement = []
        columnOfPlacement = []
        spansSpread = []
        componentOfPlacement = []
        rowsOfPlacement = []
        tableColumnsOfPlacement = []
        firstPlacement = []
        sectionOfPlacement = []
        continuationOfPlacement = []
    }
    /// Each spread's top, and how tall its tallest column is.
    private var spreadTops: [CGFloat] = []
    private var spreadHeights: [CGFloat] = []
    private var measuredWidth: CGFloat = 0

    /// The document's height: the last component's bottom plus the page's bottom padding.
    public private(set) var contentHeight: CGFloat = 0

    /// How many components have been measured, ever.
    ///
    /// Exposed because measuring is the expensive thing this class does — linear in the document,
    /// and a book is thousands of components — so the tests that matter are the ones asserting it
    /// does not happen when it needn't.
    private(set) var measuredComponents = 0

    /// Extra space after the document, so a heading near the end can still be scrolled to the
    /// top of the viewport.
    ///
    /// Without it the scroll simply clamps and the last few headings stay stuck mid-viewport,
    /// which made navigating to them land on whichever section the reading-line probe found
    /// below. The host sizes it from the viewport — see `updateTrailingParkingSpace`.
    public var trailingParkingSpace: CGFloat = 0 {
        didSet {
            guard trailingParkingSpace != oldValue else { return }
            applyHeight()
        }
    }

    /// Views currently in the hierarchy, by component index.
    private var live: [Int: NSView] = [:]
    /// Identifies a view by what it *shows*, not by where it sits.
    ///
    /// Placement indices are rebuilt from scratch on every re-pagination, so a view kept under one
    /// was liable to reappear in a slot belonging to different content — a page of a table drawn
    /// with the wrong rows for its box, clipped at the bottom or trailing empty space.
    private struct RetainKey: Hashable {
        let component: Int
        /// The rows a table fragment holds; `nil` for anything not split.
        let rows: Range<Int>?
    }

    /// Views kept even when scrolled away: a card that decoded an image or rendered a diagram
    /// should not do it again, and a code card holds the copy button's transient state.
    private var retained: [RetainKey: NSView] = [:]
    /// Prose views are the many, and are cheap to reconfigure, so they recycle.
    private var textPool: [TextComponentView] = []
    private static let textPoolLimit = 64

    /// How far beyond the viewport components are built, so scrolling does not chase them.
    private static let overscan: CGFloat = 600

    /// Focus mode: every component but this one is dimmed.
    public var focusedComponent: Int? {
        didSet {
            guard focusedComponent != oldValue else { return }
            for (index, view) in live {
                (view as? DimmableComponent)?.isDimmed =
                    focusedComponent != nil && focusedComponent != index
            }
        }
    }

    public override var isFlipped: Bool { true }

    public init(metrics: DocumentMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Content

    public func setComponents(_ components: [DocumentComponent], metrics: DocumentMetrics) {
        self.components = components
        self.metrics = metrics
        recycleEverything()
        resetPlacements()
        spreadTops = []
        spreadHeights = []
        invalidateMeasurement()
    }

    public func updateMetrics(_ metrics: DocumentMetrics) {
        self.metrics = metrics
        recycleEverything()
        invalidateMeasurement()
    }

    private func recycleEverything() {
        for (_, view) in live { retire(view) }
        live = [:]
        retained = [:]
    }

    /// Detaches every live view and drops any retained view whose content no longer exists.
    ///
    /// Called when pagination changes: `live` is keyed by placement, and those indices have just
    /// been rebuilt, so every one of them has to be re-derived from the new layout.
    private func releasePlacementViews() {
        // Through `retire`, so prose views go back to the pool rather than being reallocated on
        // every reflow.
        for (_, view) in live { retire(view) }
        live = [:]
        let keys = Set(frames.indices.map { retainKey(for: $0) })
        retained = retained.filter { keys.contains($0.key) }
    }

    private func retainKey(for placement: Int) -> RetainKey {
        RetainKey(component: componentOfPlacement[placement], rows: rowsOfPlacement[placement])
    }

    // MARK: Measurement

    /// Measures every component and lays out the stack's own height.
    ///
    /// Measuring the whole document up front rather than as it scrolls into view is what makes
    /// the scroller honest from the first frame: the previous pane had to grow the text view to a
    /// fixed point over several passes because TextKit reports a height only for what it has
    /// laid out.
    /// Fewest rows worth starting a table page with.
    ///
    /// A header and one row squeezed into the last inch of a column reads as a mistake; below
    /// this the table starts on the next page instead.
    private static let minimumTableRowsPerPage = 3

    private func measure(width: CGFloat) {
        guard width > 0, width != measuredWidth || firstPlacement.count != components.count
        else { return }
        measuredWidth = width

        resetPlacements()
        spreadTops = [contentInsets.top]
        spreadHeights = []
        firstPlacement.reserveCapacity(components.count)

        let columns = max(1, columnCount)
        let target = spreadHeight > 0 ? spreadHeight : .greatestFiniteMagnitude
        let spanWidth = width * CGFloat(columns) + Self.gutter * CGFloat(columns - 1)
        // Column cursors within the current spread, and how far down the tallest column reaches.
        var used = [CGFloat](repeating: 0, count: columns)
        var column = 0
        var spread = 0
        /// The section being placed, recorded on each placement so a break can be spotted after.
        var section = 0

        /// Ends the current spread and starts the next one below it.
        func startNewSpread() {
            let filled = used.max() ?? 0
            spreadHeights.append(filled)
            spreadTops.append(spreadTops[spread] + filled + Self.gutter)
            spread += 1
            column = 0
            used = [CGFloat](repeating: 0, count: columns)
        }

        /// Moves to the next column, or the next spread when this was the last one.
        func advance() {
            if column + 1 < columns { column += 1 } else { startNewSpread() }
        }

        /// How much of the current column is left.
        func room(after before: CGFloat) -> CGFloat { target - used[column] - before }

        /// Records one placement where the cursor is. No flow logic: callers advance first.
        func emit(component index: Int, height: CGFloat, before: CGFloat, after: CGFloat,
                  spans: Bool, rows: Range<Int>?, tableColumns: [CGFloat]?) {
            used[column] += before
            if firstPlacement.count == index { firstPlacement.append(frames.count) }
            frames.append(NSRect(x: 0, y: spreadTops[spread] + used[column],
                                 width: spans ? spanWidth : width, height: height))
            spreadOfPlacement.append(spread)
            columnOfPlacement.append(spans ? 0 : column)
            spansSpread.append(spans)
            componentOfPlacement.append(index)
            rowsOfPlacement.append(rows)
            tableColumnsOfPlacement.append(tableColumns)
            sectionOfPlacement.append(section)
            continuationOfPlacement.append(nil)

            if spans {
                // A spanning placement *is* the spread, so nothing else joins it.
                used = [CGFloat](repeating: used[0] + height + after, count: columns)
                startNewSpread()
            } else {
                used[column] += height + after
                // Trailing spacing at the foot of a column is the gap before the next spread,
                // which the gutter already provides.
                if used[column] > target { used[column] = max(used[column] - after, 0) }
            }
        }

        /// Places one component, flowing, splitting or spanning as it must.
        func placeComponent(_ index: Int) {
            let component = components[index]
            let spacing = self.spacing(for: component)
            let height = self.height(of: component, index: index, width: width)

            // Anything that fits a column flows normally: into the room that is left, or into
            // the next column when there is not enough of it.
            if columns == 1 || height <= target {
                if columns > 1, height > room(after: spacing.before), used[column] > 0 {
                    advance()
                }
                emit(component: index, height: height, before: spacing.before,
                     after: spacing.after, spans: false, rows: nil, tableColumns: nil)
                return
            }

            // A table is paginated by row, header repeated, the way a book breaks a long table.
            // Crucially it starts in the room that is *left* rather than waiting for a fresh
            // column: sizing the first page to a whole column left the reader looking at a
            // half-empty column beside a table that had jumped to the other side of the page.
            if case .widget(.table(let spec)) = component.content,
               let measured = splittableTable(spec: spec, width: width, target: target) {
                var row = 0
                var isFirst = true
                while row < measured.rows.count {
                    let before = isFirst ? spacing.before : 0
                    // Enough left here for a worthwhile chunk? If not, turn the page first.
                    let minimum = measured.header
                        + measured.rows[row...].prefix(Self.minimumTableRowsPerPage).reduce(0, +)
                    if room(after: before) < minimum, used[column] > 0 { advance() }

                    let available = room(after: before)
                    var end = row
                    var filled: CGFloat = 0
                    while end < measured.rows.count,
                          measured.header + filled + measured.rows[end] <= available {
                        filled += measured.rows[end]
                        end += 1
                    }
                    // A fresh column that still cannot hold the header and one row means the
                    // table cannot be paginated at this width; fall back to a page of its own.
                    guard end > row else { break }

                    let isLast = end == measured.rows.count
                    emit(component: index, height: measured.header + filled, before: before,
                         after: isLast ? spacing.after : 0, spans: false,
                         rows: row..<end, tableColumns: measured.columns)
                    row = end
                    isFirst = false
                }
                if row == measured.rows.count { return }
            }

            // A list is paginated at item boundaries the same way: the items are self-contained,
            // so a column break between two bullets reads as a page turn rather than a slice —
            // and it too starts in the room that is left.
            if let measured = splittableList(component, width: width, target: target) {
                var item = 0
                var isFirst = true
                while item < measured.heights.count {
                    let before = isFirst ? spacing.before : 0
                    // Enough left here for the next item? If not, turn the page first.
                    if room(after: before) < measured.heights[item], used[column] > 0 {
                        advance()
                    }

                    let available = room(after: before)
                    var end = item
                    var filled: CGFloat = 0
                    while end < measured.heights.count {
                        let gap = end > item ? measured.gaps[end - 1] : 0
                        guard filled + gap + measured.heights[end] <= available else { break }
                        filled += gap + measured.heights[end]
                        end += 1
                    }
                    // A fresh column that cannot hold even one item means the list cannot be
                    // paginated at this width; fall back to a page of its own.
                    guard end > item else { break }

                    let isLast = end == measured.heights.count
                    emit(component: index, height: filled, before: before,
                         after: isLast ? spacing.after : 0, spans: false,
                         rows: item..<end, tableColumns: nil)
                    item = end
                    isFirst = false
                }
                if item == measured.heights.count { return }
            }

            // Anything else that will not fit takes a page of its own across every column.
            // Keeping it in one column left the others empty and the reader staring at a table
            // running off the bottom beside a blank half-page — and for a wide table or a diagram
            // the full width is where it wanted to be anyway, which often makes it shorter.
            // A page of its own means a *fresh spread*, not the next column: it is emitted the
            // whole spread wide from the spread's top, so anything already placed in an earlier
            // column would sit underneath it.
            if used.contains(where: { $0 > 0 }) { startNewSpread() }
            emit(component: index,
                 height: self.height(of: component, index: index, width: spanWidth),
                 before: spacing.before, after: spacing.after, spans: true,
                 rows: nil, tableColumns: nil)
        }

        // Sections are kept whole. A heading and its content are one thought, and splitting them
        // across a column break for the sake of filling the page left a heading stranded at the
        // foot of one column with its first paragraph in the next. A section that cannot fit a
        // whole column still breaks — there is nowhere else for it to go — and then the flow,
        // table and spanning rules above take over.
        for (number, range) in sectionRanges().enumerated() {
            section = number
            let height = sectionHeight(range, width: width)
            let before = spacing(for: components[range.lowerBound]).before
            if columns > 1, height <= target, height > room(after: before), used[column] > 0 {
                advance()
            }
            for index in range { placeComponent(index) }
        }

        markContinuations()

        let lastSpreadHeight = frames.isEmpty ? 0 : used.max() ?? 0
        spreadHeights.append(lastSpreadHeight)
        contentHeight = ((spreadTops.last ?? 0) + lastSpreadHeight
                            + contentInsets.bottom).rounded(.up)
        releasePlacementViews()
        applyHeight()
        needsDisplay = true
    }

    /// Records, for every placement, whether its section carries on somewhere else.
    ///
    /// Only a section too tall for a column is ever broken, and when it is, the reader needs to be
    /// told: the foot of a column looks exactly like the end of a section.
    private func markContinuations() {
        guard columnCount > 1 else { return }
        for placement in frames.indices.dropLast() {
            let next = placement + 1
            guard sectionOfPlacement[placement] == sectionOfPlacement[next],
                  spreadOfPlacement[next] != spreadOfPlacement[placement]
            else { continue }
            continuationOfPlacement[placement] = .nextPage
        }
    }

    /// Whether the section at the foot of a page carries on over the page break.
    public func chapterContinues(afterSpread spread: Int) -> Bool {
        frames.indices.contains { placement in
            spreadOfPlacement[placement] == spread
                && continuationOfPlacement[placement] == .nextPage
        }
    }

    /// Where the section at this placement continues, if it does.
    public func continuation(atPlacement placement: Int) -> Continuation? {
        continuationOfPlacement.indices.contains(placement)
            ? continuationOfPlacement[placement] : nil
    }

    /// The placements whose section is cut off there, with where it resumes.
    public func continuationMarks() -> [(frame: NSRect, continuation: Continuation)] {
        frames.indices.compactMap { placement in
            guard let continuation = continuationOfPlacement[placement] else { return nil }
            return (frame(ofPlacement: placement), continuation)
        }
    }

    /// Test hook: the top-level section ranges the layout is using.
    /// The document split into sections: each heading and everything under it.
    ///
    /// The run before the first heading — a frontmatter card, say — is a section of its own.
    private func sectionRanges() -> [Range<Int>] {
        guard !components.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        for index in components.indices.dropFirst() where components[index].kind.isHeading {
            ranges.append(start..<index)
            start = index
        }
        ranges.append(start..<components.count)
        return ranges
    }

    /// How tall a section is, spacing between its components included.
    ///
    /// The trailing gap after the last component is left out: it is the space to whatever follows,
    /// and letting it decide whether a section fits would push sections onto the next column for
    /// the sake of a margin.
    private func sectionHeight(_ range: Range<Int>, width: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for index in range {
            let spacing = self.spacing(for: components[index])
            total += spacing.before + self.height(of: components[index], index: index, width: width)
            if index != range.upperBound - 1 { total += spacing.after }
        }
        return total
    }

    /// A table's measurements, if pagination can help it.
    ///
    /// `nil` when a single row is taller than a whole column: there is nowhere to break, and the
    /// table is better off spanning the spread.
    private func splittableTable(spec: TableSpec, width: CGFloat, target: CGFloat)
        -> (columns: [CGFloat], header: CGFloat, rows: [CGFloat])? {
        let measured = TableBlockView.rowHeights(spec: spec, width: width, metrics: metrics)
        guard let tallest = measured.rows.max(), measured.header + tallest <= target,
              measured.rows.count > 1
        else { return nil }
        return measured
    }

    /// A list's per-item measurements, if pagination can help it.
    ///
    /// `nil` for anything that is not a list of several items, and when a single item is taller
    /// than a whole column: there is nowhere to break, and the component is better off spanning
    /// the spread.
    ///
    /// A page of items is the sum of their heights plus the gaps between them, and the sum is
    /// exact: wrapping is per paragraph, TextKit collapses a container's outer paragraph
    /// spacing, and `partRange` drops the trailing separator newline — so an item measures the
    /// same alone as it lays out inside any slice.
    private func splittableList(_ component: DocumentComponent, width: CGFloat, target: CGFloat)
        -> (heights: [CGFloat], gaps: [CGFloat])? {
        guard case .text(let attributed) = component.content,
              let parts = component.parts, parts.count > 1 else { return nil }
        let heights = parts.indices.map { item in
            component.partRange(item..<item + 1).map {
                TextComponentView.height(of: attributed.attributedSubstring(from: $0),
                                         width: width)
            } ?? 0
        }
        guard let tallest = heights.max(), tallest <= target else { return nil }
        // The spacing laid out between two neighbouring items, which a page holding both must
        // include: the first one's spacing after plus the second one's spacing before.
        func style(at location: Int) -> NSParagraphStyle? {
            attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                as? NSParagraphStyle
        }
        let gaps = zip(parts, parts.dropFirst()).map { part, next in
            (style(at: NSMaxRange(part) - 1)?.paragraphSpacing ?? 0)
                + (style(at: next.location)?.paragraphSpacingBefore ?? 0)
        }
        return (heights, gaps)
    }

    /// How many spreads the document occupies. One in a single column.
    public var spreadCount: Int { max(1, spreadTops.count) }

    /// Which spread a component is on.
    public func spreadIndex(ofComponent index: Int) -> Int {
        guard firstPlacement.indices.contains(index) else { return 0 }
        return spreadOfPlacement[firstPlacement[index]]
    }

    /// A spread's rect, covering all of its columns.
    public func spreadFrame(at index: Int) -> NSRect {
        guard spreadTops.indices.contains(index), spreadHeights.indices.contains(index)
        else { return .zero }
        let geometry = columnGeometry()
        let columns = CGFloat(max(1, columnCount))
        let width = geometry.columnWidth * columns + Self.gutter * (columns - 1)
        return NSRect(x: geometry.originX(0), y: spreadTops[index],
                      width: width, height: spreadHeights[index])
    }

    /// The x offset of a column within the stack, and how wide a column is.
    private func columnGeometry() -> (columnWidth: CGFloat, originX: (Int) -> CGFloat) {
        let columns = max(1, columnCount)
        let width = contentWidth
        let total = width * CGFloat(columns) + Self.gutter * CGFloat(columns - 1)
        let left = max(0, ((bounds.width - total) / 2).rounded())
        return (width, { index in left + CGFloat(index) * (width + Self.gutter) })
    }

    private func applyHeight() {
        let total = contentHeight + trailingParkingSpace
        guard frame.height != total else { return }
        setFrameSize(NSSize(width: frame.width, height: total))
    }

    /// The gap above and below a component.
    private func spacing(for component: DocumentComponent) -> (before: CGFloat, after: CGFloat) {
        guard case .text(let attributed) = component.content, attributed.length > 0 else {
            return metrics.componentSpacing(for: component.kind)
        }
        // TextKit collapses a container's outer paragraph spacing: the first paragraph's
        // `paragraphSpacingBefore` and the last one's `paragraphSpacing` are both dropped, the
        // same way CSS collapses margins at a block's edges. Inside the old document-wide text
        // view that only happened once, at the very top and bottom of the document; now it would
        // happen at every component, so the stack applies both gaps itself. Spacing *between*
        // the paragraphs inside a component is untouched, which is what keeps list items tighter
        // than paragraphs.
        func spacing(at index: Int) -> NSParagraphStyle? {
            attributed.attribute(.paragraphStyle, at: index, effectiveRange: nil)
                as? NSParagraphStyle
        }
        return (spacing(at: 0)?.paragraphSpacingBefore ?? 0,
                spacing(at: attributed.length - 1)?.paragraphSpacing ?? 0)
    }

    private func height(of component: DocumentComponent, index: Int, width: CGFloat) -> CGFloat {
        let cache = host?.sizeCache
        let measure: () -> CGFloat = { [metrics] in
            switch component.content {
            case .text(let attributed):
                return TextComponentView.height(of: attributed, width: width)
            case .code(_, _, let lines):
                return CodeComponentView.height(lines: lines, width: width, metrics: metrics)
            case .widget(let payload):
                return BlockViewFactory.height(for: payload, width: width,
                                               metrics: metrics, host: self.host)
            case .rule:
                return 1
            }
        }
        let counted: () -> CGFloat = { [weak self] in
            self?.measuredComponents += 1
            return measure()
        }
        guard let cache else { return counted() }
        return cache.height(for: index, width: width, measure: counted)
    }

    /// A placement's frame.
    private func frame(ofPlacement placement: Int) -> NSRect {
        guard frames.indices.contains(placement) else { return .zero }
        let geometry = columnGeometry()
        var frame = frames[placement]
        frame.origin.x = geometry.originX(columnOfPlacement[placement])
        frame.size.width = spansSpread[placement]
            ? geometry.columnWidth * CGFloat(max(1, columnCount))
                + Self.gutter * CGFloat(max(0, columnCount - 1))
            : geometry.columnWidth
        return frame
    }

    /// The component's frame — its first page, if it was paginated across several.
    public func frame(ofComponent index: Int) -> NSRect {
        guard firstPlacement.indices.contains(index) else { return .zero }
        return frame(ofPlacement: firstPlacement[index])
    }

    /// Whether a component takes a page of its own across every column.
    public func spans(component index: Int) -> Bool {
        guard firstPlacement.indices.contains(index) else { return false }
        return spansSpread[firstPlacement[index]]
    }

    /// How many pages a component was split across. One for everything but a long table.
    public func placementCount(ofComponent index: Int) -> Int {
        componentOfPlacement.reduce(0) { $1 == index ? $0 + 1 : $0 }
    }

    /// The row — or list-item — ranges a split component's pages hold, in reading order.
    ///
    /// The contract worth testing: they tile the content exactly — in order, no gap, nothing on
    /// two pages — because a paginated table or list that drops or repeats something is worse
    /// than one that overflows.
    func rowRanges(ofComponent index: Int) -> [Range<Int>] {
        frames.indices.compactMap { placement in
            componentOfPlacement[placement] == index ? rowsOfPlacement[placement] : nil
        }
    }

    /// Every component with any part of it inside `rect`.
    ///
    /// Walks placements, not components: a component can hold several pages, and a page is the unit
    /// that has a position.
    public func components(intersecting rect: NSRect) -> Set<Int> {
        var result: Set<Int> = []
        for placement in frames.indices where frame(ofPlacement: placement).intersects(rect) {
            result.insert(componentOfPlacement[placement])
        }
        return result
    }

    /// The frames of every page of a component.
    func frames(ofComponent index: Int) -> [NSRect] {
        frames.indices.compactMap { placement in
            componentOfPlacement[placement] == index ? frame(ofPlacement: placement) : nil
        }
    }

    /// Where the viewport's top edge should sit to bring a component into view.
    ///
    /// In a spread, that is the spread's own top: aligning on a component in a later column
    /// would cut every column in half and break the reading order.
    public func alignmentY(forComponent index: Int) -> CGFloat {
        guard columnCount > 1, firstPlacement.indices.contains(index) else {
            return frame(ofComponent: index).minY
        }
        return spreadTops[spreadOfPlacement[firstPlacement[index]]]
    }

    /// The component a reader at this scroll offset has reached.
    public func componentIndex(atY y: CGFloat) -> Int? {
        guard !frames.isEmpty else { return nil }
        guard columnCount > 1 else {
            var result: Int?
            // The last placement starting at or above `y`: a y in the gap between two of them
            // belongs to the one above.
            for (placement, frame) in frames.enumerated() {
                if frame.minY <= y { result = componentOfPlacement[placement] } else { break }
            }
            return result ?? 0
        }

        // A spread has no single reading position: every column is on screen at once, and they
        // share the same y range, so a probe cannot say which of them the reader is in.
        //
        // What it *can* say is how far the spread has travelled — and a spread is a screenful, so
        // the reader crosses its whole reading order in that distance. Position is therefore
        // taken as a fraction of the spread's reading order. Restricting the probe to the first
        // column instead, as this did, meant a heading in a later column only became
        // current once the *next* spread arrived: the outline lagged a page behind the page.
        let spread = spreadTops.lastIndex { $0 <= y } ?? 0
        let placements = frames.indices.filter { spreadOfPlacement[$0] == spread }
        guard !placements.isEmpty else { return 0 }

        let height = max(1, spreadHeights.indices.contains(spread)
                            ? spreadHeights[spread] : frame.height)
        let progress = min(1, max(0, (y - spreadTops[spread]) / height))
        let step = min(placements.count - 1, Int(progress * CGFloat(placements.count)))
        return componentOfPlacement[placements[step]]
    }

    // MARK: Layout

    /// The width components are measured and laid out at.
    private var contentWidth: CGFloat {
        columnWidth > 0 ? columnWidth : bounds.width
    }

    public override func layout() {
        super.layout()
        measure(width: contentWidth)
        populateVisible()
    }

    /// Measures and positions the current components right now, without waiting for AppKit's
    /// layout pass. The peek card sizes itself *from* the measured height before it has ever
    /// been laid out or shown, so it cannot rely on `layout()` having run — while the reading
    /// pane keeps to the ordinary layout path.
    public func ensureMeasured() {
        measure(width: contentWidth)
    }

    /// Builds the placements near the viewport and retires the rest.
    public func populateVisible() {
        guard !components.isEmpty, !frames.isEmpty else { return }
        let viewport = visibleRect.isEmpty ? bounds : visibleRect
        let wanted = viewport.insetBy(dx: 0, dy: -Self.overscan)

        var keep = Set<Int>()
        for placement in frames.indices {
            let frame = self.frame(ofPlacement: placement)
            guard frame.maxY >= wanted.minY, frame.minY <= wanted.maxY else { continue }
            keep.insert(placement)
            let view = live[placement] ?? install(placement)
            if view.frame != frame { view.frame = frame }
        }

        for (placement, view) in live where !keep.contains(placement) {
            retire(view)
            live.removeValue(forKey: placement)
        }
    }

    private func install(_ placement: Int) -> NSView {
        let view = makeView(for: placement)
        view.frame = frame(ofPlacement: placement)
        (view as? DimmableComponent)?.isDimmed =
            focusedComponent != nil && focusedComponent != componentOfPlacement[placement]
        addSubview(view)
        live[placement] = view
        return view
    }

    private func makeView(for placement: Int) -> NSView {
        let key = retainKey(for: placement)
        if let kept = retained[key] { return kept }
        let index = key.component

        switch components[index].content {
        case .text(let attributed):
            let view = textPool.popLast() ?? TextComponentView()
            view.componentDelegate = linkDelegate
            view.peekDelegate = linkPeekDelegate
            // A page of a split list holds just its own items' slice of the text.
            let content = key.rows.flatMap { rows in
                components[index].partRange(rows).map(attributed.attributedSubstring(from:))
            } ?? attributed
            view.configure(with: content, kind: components[index].kind)
            return view

        case .code(let label, let source, let lines):
            let view = CodeComponentView(label: label, source: source, lines: lines,
                                         metrics: metrics, host: host)
            retained[key] = view
            return view

        case .widget(.table(let spec)):
            // A page of a split table: the same header, this page's rows, and the widths the
            // whole table measured to.
            let sliced = key.rows.map {
                TableSpec(header: spec.header, rows: Array(spec.rows[$0]),
                          alignments: spec.alignments)
            } ?? spec
            let view = TableBlockView(spec: sliced, metrics: metrics, host: host,
                                      columnWidths: tableColumnsOfPlacement[placement])
            retained[key] = view
            return view

        case .widget(let payload):
            let view = BlockViewFactory.makeView(for: payload, host: host)
            retained[key] = view
            return view

        case .rule:
            return RuleComponentView()
        }
    }

    private func retire(_ view: NSView) {
        view.removeFromSuperview()
        guard let text = view as? TextComponentView,
              textPool.count < Self.textPoolLimit else { return }
        textPool.append(text)
    }

    // MARK: Page furniture

    /// Where the divider between two pages sits, or `nil` after the last one.
    public func pageBreakY(after spread: Int) -> CGFloat? {
        guard spread >= 0, spread + 1 < spreadTops.count else { return nil }
        return (spreadFrame(at: spread).maxY + Self.gutter / 2).rounded()
    }

    /// Draws a divider between pages.
    ///
    /// Dashed, and tinted with the accent, because it has to be legible as *chrome*: a solid
    /// hairline is what a `---` in the source renders as, and a reader should never have to wonder
    /// whether a line came from the document or from the app. Nothing is drawn between the columns
    /// of a page — the page break says where a page ends, which is the only thing a rule was ever
    /// needed for.
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard columnCount > 1, spreadTops.count > 1 else { return }

        // A hairline's weight, brightened: the accent tint and the dash rhythm are what make it
        // read as chrome, so the line need not be heavy to say "the page ends here".
        let weight: CGFloat = 1
        for index in spreadTops.indices.dropLast() {
            guard let y = pageBreakY(after: index) else { continue }
            let spread = spreadFrame(at: index)
            guard dirtyRect.intersects(NSRect(x: spread.minX, y: y - 2,
                                              width: spread.width, height: 4)) else { continue }

            let path = NSBezierPath()
            path.move(to: NSPoint(x: spread.minX, y: y))
            path.line(to: NSPoint(x: spread.maxX, y: y))
            path.lineWidth = weight
            path.lineCapStyle = .round
            path.setLineDash([2, 7], count: 2, phase: 0)
            Ink.accent.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
    }

    // MARK: Navigation feedback

    /// How long the landing flash takes to fade. Internal so a test need not wait for it.
    static var flashDuration: TimeInterval = 1.1
    /// Strength of the flash at its brightest.
    private static let flashTint: CGFloat = 0.22
    /// How far the flash extends past the component, so it reads as a glow around the block
    /// rather than a box drawn on it.
    private static let flashInset = NSSize(width: 10, height: 7)

    /// Flashes a component's background.
    ///
    /// Navigating in a spread can land the reader anywhere on the page — the foot of a column, the
    /// top of the right-hand one — and a heading that simply appears somewhere is easy to miss.
    /// The flash says *here*, then gets out of the way. Every page of a split component flashes,
    /// because all of them are what the reader asked for.
    public func flash(component index: Int) {
        for frame in frames(ofComponent: index) { addFlash(in: frame) }
    }

    private func addFlash(in frame: NSRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let glow = FlashView(frame: frame.insetBy(dx: -Self.flashInset.width,
                                                  dy: -Self.flashInset.height))
        glow.tint = Ink.accent.withAlphaComponent(Self.flashTint)
        // Behind everything: the component's own view draws over it, so text stays text.
        addSubview(glow, positioned: .below, relativeTo: nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.flashDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glow.animator().alphaValue = 0
        }, completionHandler: { glow.removeFromSuperview() })
    }

    /// The flashes currently on screen, for tests.
    var flashCount: Int { subviews.filter { $0 is FlashView }.count }

    // MARK: Selection

    /// Clears the selection everywhere except in `keeper`.
    ///
    /// Selection is per component, so focusing one has to release the last one — otherwise two
    /// blocks look selected at once and ⌘C is ambiguous about which it takes. The walk is over
    /// the view tree rather than `live`, because a code card's body is a text view *inside* a
    /// component, not a component itself.
    public func clearSelections(except keeper: NSView? = nil) {
        func clear(_ view: NSView) {
            if let text = view as? TextComponentView, text !== keeper {
                text.setSelectedRange(NSRange(location: 0, length: 0))
            }
            view.subviews.forEach(clear)
        }
        subviews.forEach(clear)
    }
}

/// The landing glow behind a navigated-to component.
///
/// Drawn rather than layer-backed: a layer composites unpredictably against the pane's vibrancy,
/// and does not appear in the headless snapshots this project checks itself with.
final class FlashView: NSView {
    var tint: NSColor = .clear { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    /// Never in the way of a click: it is feedback, not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}
