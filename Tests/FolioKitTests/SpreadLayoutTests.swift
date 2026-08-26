import AppKit
import XCTest
@testable import FolioKit

/// The two-column spread: two pages of the document on one screen.
///
/// Two columns mean pagination — components fill the left column, then the right, then the next
/// spread below — which is the only way two pages fit a screen. The spreads stack vertically, so
/// scrolling stays scrolling.
final class SpreadLayoutTests: XCTestCase {

    let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    func sampleDocument() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    func pane(width: CGFloat, height: CGFloat = 700) throws -> NativeDocumentView {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try sampleDocument(), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return view
    }

    /// A column needs a full measure plus its gutter inside the page margins; anything less keeps
    /// the count it had, because cramming narrower columns in is worse than leaving width unused.
    func testColumnCountFollowsTheAvailableWidth() {
        func needed(_ columns: Int) -> CGFloat {
            metrics.measure * CGFloat(columns)
                + DocumentStackView.gutter * CGFloat(columns - 1)
                + DocumentMetrics.minimumPadding * 2
        }
        func count(_ pane: CGFloat) -> Int {
            NativeDocumentView.columnCount(fitting: pane, metrics: metrics, layout: .automatic)
        }
        // Well past any count a display holds, to show nothing in here stops at a number.
        for columns in 1...8 {
            XCTAssertEqual(count(needed(columns) + 1), columns,
                           "\(columns) columns fit and were not used")
            // One column is the floor — there is nothing narrower to fall back to.
            guard columns > 1 else { continue }
            XCTAssertEqual(count(needed(columns) - 1), columns - 1,
                           "\(columns) columns were squeezed into a pane that holds \(columns - 1)")
        }
        XCTAssertEqual(count(paneWidth(forColumns: 1)), 1)
    }

    /// Automatic has no ceiling: the pane is the only thing that decides.
    ///
    /// The count this app was capped at — three — is not special. A column is a full reading
    /// measure whatever the count, so an ultrawide display that holds ten gets ten, and a reader
    /// who would rather cross a narrower page pins one instead.
    func testAutomaticIsBoundedOnlyByThePane() {
        let step = metrics.measure + DocumentStackView.gutter
        for pane in [3000.0, 4500.0, 6000.0] as [CGFloat] {
            let expected = Int((pane - DocumentMetrics.minimumPadding * 2
                                    + DocumentStackView.gutter) / step)
            XCTAssertGreaterThan(expected, 3, "the fixture pane should exceed the old cap")
            XCTAssertEqual(
                NativeDocumentView.columnCount(fitting: pane, metrics: metrics,
                                               layout: .automatic),
                expected,
                "a \(Int(pane))pt pane holds \(expected) columns at this measure"
            )
        }
    }

    /// A pinned count is a ceiling, not a promise: it is honoured when the width is there and
    /// clamped to what fits when it is not, because a column is only ever the measure wide.
    func testAPinnedCountIsHonouredAndClamped() {
        func count(_ pane: CGFloat, _ layout: AppSettings.ColumnLayout) -> Int {
            NativeDocumentView.columnCount(fitting: pane, metrics: metrics, layout: layout)
        }
        // A pane that holds far more than any of these still gives exactly what was asked for.
        for pinned in 1...6 {
            XCTAssertEqual(count(6000, .fixed(pinned)), pinned,
                           "\(pinned) columns asked for, another number given")
        }
        // Pinned wider than the pane: two is what fits, so two is what it gets.
        XCTAssertEqual(count(paneWidth(forColumns: 2), .three), 2)
        XCTAssertEqual(count(paneWidth(forColumns: 1), .three), 1)
        XCTAssertEqual(count(paneWidth(forColumns: 3), .fixed(6)), 3)
    }

    /// The `spreadLayout` Bool this setting replaced, read through rather than rewritten.
    func testTheLegacySpreadLayoutBoolMigrates() throws {
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppSettings(defaults: defaults).columnLayout, .automatic,
                       "a reader with neither key should get automatic")

        defaults.set(false, forKey: "spreadLayout")
        XCTAssertEqual(AppSettings(defaults: defaults).columnLayout, .one,
                       "the spread turned off meant one column")

        defaults.set(true, forKey: "spreadLayout")
        XCTAssertEqual(AppSettings(defaults: defaults).columnLayout, .automatic,
                       "the spread left on meant as many columns as fit")

        // An explicit choice outranks the Bool it replaced.
        defaults.set(AppSettings.ColumnLayout.two.rawValue, forKey: "columnLayout")
        defaults.set(false, forKey: "spreadLayout")
        XCTAssertEqual(AppSettings(defaults: defaults).columnLayout, .two)
    }

    func testWidePaneUsesTwoColumns() throws { try assertPaneUses(columns: 2) }

    /// A pane wide enough for three uses three. The packing pass was always written for any
    /// number of columns; until the cap was lifted only two of them were ever asked for.
    func testVeryWidePaneUsesThreeColumns() throws { try assertPaneUses(columns: 3) }

    /// And four on an ultrawide, which is the point of there being no cap.
    func testUltrawidePaneUsesFourColumns() throws { try assertPaneUses(columns: 4) }

    private func assertPaneUses(columns: Int) throws {
        let view = try pane(width: paneWidth(forColumns: columns))
        XCTAssertEqual(view.stackView.columnCount, columns)

        let built = try XCTUnwrap(view.built)
        let stack = view.stackView
        let frames = built.components.indices.map { stack.frame(ofComponent: $0) }
        let edges = Set(frames.map { Int($0.minX) })
        XCTAssertEqual(edges.count, columns,
                       "components did not land in \(columns) distinct columns")

        // Every component is a column wide — not the whole pane. A block too tall for a column
        // is the exception: it takes a page of its own across all of them.
        let spread = metrics.measure * CGFloat(columns)
            + DocumentStackView.gutter * CGFloat(columns - 1)
        for index in built.components.indices {
            let expected = stack.spans(component: index) ? spread : metrics.measure
            XCTAssertEqual(frames[index].width, expected, accuracy: 1,
                           "component \(index) is neither a column nor a spread wide")
        }
    }

    /// Reading order is preserved: an earlier column of a page holds the earlier components.
    func testReadingOrderRunsDownThenAcross() throws {
        try assertReadingOrderRunsDownThenAcross(columns: 2)
    }

    func testReadingOrderRunsDownThenAcrossThreeColumns() throws {
        try assertReadingOrderRunsDownThenAcross(columns: 3)
    }

    private func assertReadingOrderRunsDownThenAcross(columns: Int) throws {
        let view = try pane(width: paneWidth(forColumns: columns), height: 600)
        XCTAssertEqual(view.stackView.columnCount, columns)
        let built = try XCTUnwrap(view.built)
        let stack = view.stackView

        // Which column a component is in, taken from the distinct left edges in order — the
        // invariant holds for any number of them, where a midpoint test only worked for two.
        let edges = Set(built.components.indices.map {
            Int(stack.frame(ofComponent: $0).minX)
        }).sorted()
        XCTAssertEqual(edges.count, columns, "components did not fill every column")
        func column(_ index: Int) -> Int {
            edges.firstIndex(of: Int(stack.frame(ofComponent: index).minX)) ?? 0
        }

        // Within one page the column never runs backwards as the document goes on.
        for earlier in built.components.indices {
            for later in built.components.indices where later > earlier {
                guard abs(stack.alignmentY(forComponent: earlier)
                            - stack.alignmentY(forComponent: later)) < 1 else { continue }
                XCTAssertLessThanOrEqual(column(earlier), column(later),
                                         "component \(later) sits in a column left of \(earlier) "
                                             + "on the same page")
            }
        }
    }

    /// Components in the same column never overlap.
    func testColumnsDoNotOverlap() throws {
        let view = try pane(width: paneWidth(forColumns: 2), height: 600)
        let built = try XCTUnwrap(view.built)
        let stack = view.stackView

        var lastBottom: [Int: CGFloat] = [:]
        for index in built.components.indices {
            let frame = stack.frame(ofComponent: index)
            let key = Int(frame.minX)
            if let bottom = lastBottom[key], frame.minY < bottom - 0.5 {
                // A new spread resets the column, which is a legitimate jump upward.
                XCTAssertGreaterThan(stack.alignmentY(forComponent: index), 0)
            }
            lastBottom[key] = frame.maxY
        }
    }

    /// Navigation aligns on the spread, not on the component: aligning mid-column would cut both
    /// columns in half.
    func testNavigationAlignsOnSpreads() throws {
        let view = try pane(width: paneWidth(forColumns: 2), height: 600)
        let built = try XCTUnwrap(view.built)
        let stack = view.stackView

        for index in built.components.indices {
            let alignment = stack.alignmentY(forComponent: index)
            let frame = stack.frame(ofComponent: index)
            XCTAssertLessThanOrEqual(alignment, frame.minY + 1,
                                     "a component's spread starts below the component")
        }
        XCTAssertEqual(Set(built.components.indices.map { stack.alignmentY(forComponent: $0) })
            .count, Set(built.components.indices.map { stack.alignmentY(forComponent: $0) }).count)
    }

    /// A narrow pane keeps the single-column layout, unchanged.
    func testNarrowPaneIsUnchanged() throws {
        let view = try pane(width: paneWidth(forColumns: 1))
        XCTAssertEqual(view.stackView.columnCount, 1)
        let built = try XCTUnwrap(view.built)
        for index in 1..<built.components.count {
            let previous = view.stackView.frame(ofComponent: index - 1)
            let current = view.stackView.frame(ofComponent: index)
            XCTAssertGreaterThanOrEqual(current.minY, previous.maxY - 0.5)
            XCTAssertEqual(current.minX, previous.minX, accuracy: 0.5)
        }
    }
}

/// The page furniture: what tells a reader the page continues to the right.
///
/// Two columns with a gap between them look like a document that continues *below*, so the natural
/// move at the foot of the left column is to keep scrolling — straight past the other half of the
/// page. Each spread is therefore drawn as a page: a sheet, a rule down its gutter, and a number.
extension SpreadLayoutTests {

    /// Every component sits inside the page that is drawn around it.
    func testPagesEncloseTheirComponents() throws {
        let view = try pane(width: paneWidth(forColumns: 2), height: 600)
        let stack = view.stackView
        let built = try XCTUnwrap(view.built)
        XCTAssertGreaterThan(stack.spreadCount, 1, "the fixture should span several pages")

        for index in built.components.indices {
            let page = stack.spreadFrame(at: stack.spreadIndex(ofComponent: index))
            let frame = stack.frame(ofComponent: index)
            XCTAssertGreaterThanOrEqual(frame.minY, page.minY - 0.5,
                                        "component \(index) starts above its page")
            XCTAssertLessThanOrEqual(frame.minY, page.maxY + 0.5,
                                     "component \(index) starts below its page")
            XCTAssertGreaterThanOrEqual(frame.minX, page.minX - 0.5)
            XCTAssertLessThanOrEqual(frame.maxX, page.maxX + 0.5)
        }
    }

    /// Pages are ordered, do not overlap, and leave the gutter between them.
    func testPagesAreOrderedAndSeparated() throws {
        let view = try pane(width: paneWidth(forColumns: 2), height: 600)
        let stack = view.stackView
        for index in 1..<stack.spreadCount {
            let previous = stack.spreadFrame(at: index - 1)
            let current = stack.spreadFrame(at: index)
            XCTAssertGreaterThanOrEqual(current.minY, previous.maxY,
                                        "page \(index) overlaps the page above it")
            XCTAssertEqual(current.minX, previous.minX, accuracy: 0.5)
            XCTAssertEqual(current.width, previous.width, accuracy: 0.5)
        }
    }

    /// A single column is not paginated, so it gets no page furniture to explain.
    func testSingleColumnHasOnePage() throws {
        let view = try pane(width: paneWidth(forColumns: 1))
        XCTAssertEqual(view.stackView.columnCount, 1)
        XCTAssertEqual(view.stackView.spreadCount, 1)
    }

    /// Drawing is exercised, since it reaches for spread geometry that must exist for every index.
    func testDrawingThePagesIsSafe() throws {
        let view = try pane(width: paneWidth(forColumns: 2), height: 600)
        let stack = view.stackView
        let region = NSRect(x: 0, y: 0, width: stack.frame.width,
                            height: min(2000, stack.frame.height))
        let rep = try XCTUnwrap(stack.bitmapImageRepForCachingDisplay(in: region))
        stack.cacheDisplay(in: region, to: rep)
    }
}

/// What happens to a component that does not fit a column.
///
/// It used to keep its column slot: the other column was left empty and the component ran off the
/// bottom of the spread on its own — a heading stranded beside a table disappearing off the page.
extension SpreadLayoutTests {

    /// A table of contents from a converted book: hundreds of rows, far taller than a column.
    private func longTableDocument(rows: Int) throws -> MarkdownDocument {
        var lines = ["# Contents", "", "| Chapter | Page |", "| --- | --- |"]
        for row in 1...rows {
            lines.append("| \(row). A Section Title From The Original Layout | \(row) |")
        }
        lines += ["", "After the table.", ""]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-table-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MarkdownDocument(url: url)
    }

    private func paneWithLongTable() throws -> (NativeDocumentView, Int) {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: paneWidth(forColumns: 2), height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try longTableDocument(rows: 200), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let table = try XCTUnwrap(view.built?.components.firstIndex {
            if case .widget(.table) = $0.content { return true } else { return false }
        })
        return (view, table)
    }

    /// A split table starts in the room that is left, not on the next page.
    ///
    /// Sizing its first page to a whole column meant the table jumped to the other side of the
    /// spread while the reader looked at a column that was two thirds empty.
    func testASplitTableStartsInTheRoomThatIsLeft() throws {
        let (view, table) = try paneWithLongTable()
        let stack = view.stackView
        XCTAssertGreaterThan(table, 0, "the fixture should have content before the table")

        let previous = stack.frame(ofComponent: table - 1)
        let pages = stack.frames(ofComponent: table)
        let first = try XCTUnwrap(pages.first)

        XCTAssertEqual(first.minX, previous.minX, accuracy: 1,
                       "the table turned the page instead of using the room left in the column")
        XCTAssertGreaterThanOrEqual(first.minY, previous.maxY - 1,
                                    "the table overlaps what precedes it")
        XCTAssertEqual(stack.spreadIndex(ofComponent: table),
                       stack.spreadIndex(ofComponent: table - 1),
                       "the table left its own page's first column empty")
        // And that first page is smaller than a full one, because it filled a remainder.
        if pages.count > 1 {
            XCTAssertLessThan(first.height, try XCTUnwrap(pages.dropFirst().first).height,
                              "the first page did not fill a remainder")
        }
    }

    func testALongTableIsPaginated() throws {
        let (view, table) = try paneWithLongTable()
        let stack = view.stackView
        XCTAssertEqual(stack.columnCount, 2)
        XCTAssertGreaterThan(stack.placementCount(ofComponent: table), 1,
                             "the table was not split across pages")
        XCTAssertFalse(stack.spans(component: table),
                       "a splittable table should flow through the columns, not take whole pages")
    }

    /// The pages tile the table exactly: in order, no gap, no row shown twice.
    func testSplitTablePagesTileTheRows() throws {
        let (view, table) = try paneWithLongTable()
        let ranges = view.stackView.rowRanges(ofComponent: table)
        XCTAssertEqual(ranges.count, view.stackView.placementCount(ofComponent: table))

        var expected = 0
        for range in ranges {
            XCTAssertEqual(range.lowerBound, expected, "pages skip or repeat rows: \(ranges)")
            XCTAssertGreaterThan(range.count, 0, "an empty page of table")
            expected = range.upperBound
        }
        guard case .widget(.table(let spec)) = try XCTUnwrap(view.built).components[table].content
        else { return XCTFail("not a table") }
        XCTAssertEqual(expected, spec.rows.count, "the last rows never got a page")
    }

    /// No page of the table is taller than the page it sits on.
    func testSplitTablePagesFitTheirColumn() throws {
        let (view, table) = try paneWithLongTable()
        let stack = view.stackView
        let target = stack.spreadHeight
        XCTAssertGreaterThan(target, 0)
        for frame in stack.frames(ofComponent: table) {
            XCTAssertLessThanOrEqual(frame.height, target + 1,
                                     "a page of the table overflows the column")
        }
    }

    /// A component that cannot be split takes a page of its own, across every column, rather than
    /// leaving the others empty.
    func testUnsplittableTallComponentSpansThePage() throws {
        try assertTallComponentSpansThePage(columns: 2)
    }

    /// And it spans all three when there are three: a spanning block *is* the page, and the extra
    /// width is often what makes it shorter.
    func testUnsplittableTallComponentSpansAThreeColumnPage() throws {
        try assertTallComponentSpansThePage(columns: 3)
    }

    private func assertTallComponentSpansThePage(columns: Int) throws {
        var lines = ["# Long code", ""]
        lines += ["```python"]
        for index in 1...200 { lines.append("value_\(index) = compute(\(index))") }
        lines += ["```", "", "After the code.", ""]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-code-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: paneWidth(forColumns: columns), height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try MarkdownDocument(url: url), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        let stack = view.stackView
        XCTAssertEqual(stack.columnCount, columns)
        let code = try XCTUnwrap(view.built?.components.firstIndex {
            if case .code = $0.content { return true } else { return false }
        })
        XCTAssertTrue(stack.spans(component: code), "the tall card did not take a page of its own")
        let column = stack.frame(ofComponent: 0).width
        XCTAssertEqual(stack.frame(ofComponent: code).width,
                       column * CGFloat(columns) + DocumentStackView.gutter * CGFloat(columns - 1),
                       accuracy: 1,
                       "a spanning component should be the whole page wide")

        // A page of its own means a fresh spread: it is emitted from the spread's top the whole
        // page wide, so following the heading into the same spread drew it *over* the heading.
        try assertNoComponentOverlaps(in: view)
    }

    /// No two components' pages may share any pixels, whatever pagination decided for them.
    func assertNoComponentOverlaps(in view: NativeDocumentView,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let stack = view.stackView
        let componentCount = try XCTUnwrap(view.built).components.count
        let placed = (0..<componentCount).flatMap { index in
            stack.frames(ofComponent: index).map { (component: index, frame: $0) }
        }
        for (position, first) in placed.enumerated() {
            for second in placed.dropFirst(position + 1)
            where first.component != second.component {
                XCTAssertFalse(
                    first.frame.intersects(second.frame),
                    "components \(first.component) and \(second.component) overlap: "
                        + "\(first.frame) vs \(second.frame)",
                    file: file, line: line
                )
            }
        }
    }

    /// A single column is not paginated, so nothing is split there.
    func testSingleColumnDoesNotSplitTables() throws {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: paneWidth(forColumns: 1), height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try longTableDocument(rows: 200), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let table = try XCTUnwrap(view.built?.components.firstIndex {
            if case .widget(.table) = $0.content { return true } else { return false }
        })
        XCTAssertEqual(view.stackView.columnCount, 1)
        XCTAssertEqual(view.stackView.placementCount(ofComponent: table), 1)
    }
}

/// A view has to match the slot it is placed in, across a re-pagination.
///
/// Views are kept when they scroll away, so a card that decoded an image or highlighted code does
/// not do it twice. They used to be kept under their *placement index* — and those are rebuilt from
/// scratch whenever pagination changes, so a page of a table came back in a slot sized for
/// different rows: clipped at the bottom, or trailing a band of empty space.
extension SpreadLayoutTests {

    private func paneWithTableRows(_ rows: Int, width: CGFloat = paneWidth(forColumns: 2),
                                   height: CGFloat = 900) throws -> NativeDocumentView {
        var lines = ["# Contents", "", "An introductory paragraph before the table.", "",
                     "| Chapter | Page |", "| --- | --- |"]
        for row in 1...rows { lines.append("| \(row). A section of the original book | \(row) |") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-stale-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try MarkdownDocument(url: url), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return view
    }

    /// Every built page of a table fills its box exactly — no clipping, no empty band.
    private func assertTablePagesFitTheirBoxes(_ view: NativeDocumentView,
                                              _ label: String, line: UInt = #line) {
        let pages = view.stackView.subviews.compactMap { $0 as? TableBlockView }
        XCTAssertFalse(pages.isEmpty, "no page of the table was built (\(label))", line: line)
        for page in pages {
            let content = TableBlockView.height(spec: page.renderedSpec, width: page.frame.width,
                                                metrics: metrics,
                                                columnWidths: page.imposedColumnWidths)
            XCTAssertEqual(page.frame.height, content, accuracy: 1,
                           "a page holding \(page.renderedSpec.rows.count) rows is in a box of "
                               + "\(Int(page.frame.height))pt but needs \(Int(content))pt (\(label))",
                           line: line)
        }
    }

    func testTablePagesFitTheirBoxes() throws {
        let view = try paneWithTableRows(200)
        assertTablePagesFitTheirBoxes(view, "initial")
    }

    /// The case that broke: pagination changes, and the kept views have to follow.
    func testTablePagesStillFitAfterRepagination() throws {
        let view = try paneWithTableRows(200)
        assertTablePagesFitTheirBoxes(view, "initial")

        // Shorter pages, as a resized window would produce.
        view.stackView.spreadHeight = 520
        view.stackView.layoutSubtreeIfNeeded()
        view.stackView.populateVisible()
        for _ in 0..<10 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        assertTablePagesFitTheirBoxes(view, "after shorter pages")

        // And taller ones, which is the direction that left empty space.
        view.stackView.spreadHeight = 1100
        view.stackView.layoutSubtreeIfNeeded()
        view.stackView.populateVisible()
        for _ in 0..<10 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        assertTablePagesFitTheirBoxes(view, "after taller pages")
    }
}

/// The divider between pages, and nothing between the columns of one.
extension SpreadLayoutTests {

    func testPageBreaksSitBetweenPages() throws {
        let view = try pane(width: paneWidth(forColumns: 2), height: 600)
        let stack = view.stackView
        XCTAssertGreaterThan(stack.spreadCount, 1, "the fixture should span several pages")
        XCTAssertNil(stack.pageBreakY(after: stack.spreadCount - 1),
                     "there is nothing after the last page to divide it from")
        XCTAssertNil(stack.pageBreakY(after: -1))

        for index in 0..<(stack.spreadCount - 1) {
            let y = try XCTUnwrap(stack.pageBreakY(after: index))
            let above = stack.spreadFrame(at: index)
            let below = stack.spreadFrame(at: index + 1)
            XCTAssertGreaterThan(y, above.maxY,
                                 "the divider is drawn over the page above it")
            XCTAssertLessThan(y, below.minY,
                              "the divider is drawn over the page below it")
        }
    }

    /// A single column is not paginated, so there is nothing to divide.
    func testSingleColumnHasNoPageBreaks() throws {
        let view = try pane(width: paneWidth(forColumns: 1))
        XCTAssertEqual(view.stackView.columnCount, 1)
        XCTAssertNil(view.stackView.pageBreakY(after: 0))
    }
}

/// Saying where a cut-off section carries on.
///
/// The foot of a column looks exactly like the end of a section, so a section that ran out of room
/// has to say so — and say *where*: across to the other column, or over the page.
extension SpreadLayoutTests {

    private func longSectionDocument() throws -> MarkdownDocument {
        var lines = ["# Long chapter", "", "## A section that runs on", ""]
        for index in 1...40 {
            lines += ["Paragraph \(index) of a section that keeps going well past the height of a "
                        + "single column, so the layout has no choice but to break it.", ""]
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-cont-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MarkdownDocument(url: url)
    }

    private func paneShowing(_ document: MarkdownDocument,
                            width: CGFloat) throws -> NativeDocumentView {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: document, metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return view
    }

    func testAPageThatCarriesOnIsMarked() throws {
        let view = try paneShowing(try longSectionDocument(), width: paneWidth(forColumns: 2))
        let stack = view.stackView
        XCTAssertEqual(stack.columnCount, 2)
        XCTAssertGreaterThan(stack.spreadCount, 1, "the fixture should span several pages")

        // The section runs past the first page, so that page's break carries the marker.
        XCTAssertTrue(stack.chapterContinues(afterSpread: 0),
                      "a section running onto the next page was not marked")
        // Nothing is marked after the last page — there is no next page to carry on to.
        XCTAssertFalse(stack.chapterContinues(afterSpread: stack.spreadCount - 1))

        // Only page breaks are recorded: both columns of a page are on screen together, so a
        // section crossing between them needs no telling.
        for mark in stack.continuationMarks() {
            XCTAssertEqual(mark.continuation, .nextPage)
        }
    }

    /// A page whose last section ends on it is not marked: the marker means "there is more of
    /// this", and a completed section has none.
    func testAPageThatEndsItsSectionIsNotMarked() throws {
        let view = try pane(width: paneWidth(forColumns: 2), height: 700)
        for spread in 0..<view.stackView.spreadCount {
            XCTAssertFalse(view.stackView.chapterContinues(afterSpread: spread),
                           "page \(spread) ends its sections but was marked as continuing")
        }
    }

    /// A single column is one continuous flow: there are no pages, so nothing is ever carried on
    /// to one.
    func testSingleColumnHasNoContinuationMarks() throws {
        let view = try paneShowing(try longSectionDocument(), width: paneWidth(forColumns: 1))
        XCTAssertEqual(view.stackView.columnCount, 1)
        XCTAssertTrue(view.stackView.continuationMarks().isEmpty)
        XCTAssertFalse(view.stackView.chapterContinues(afterSpread: 0))
    }
}

/// What happens to a list that does not fit a column.
///
/// It is paginated at item boundaries, the way a table breaks at rows: the items are
/// self-contained, so a column break between two bullets reads as a page turn. It used to take
/// a page of its own across every column, which for prose meant lines a whole spread wide — a
/// reading measure nobody chose.
extension SpreadLayoutTests {

    /// A bullet list far taller than a column, every item long enough to wrap.
    private func longListDocument(items: Int) throws -> MarkdownDocument {
        var lines = ["# Decisions", ""]
        for item in 1...items {
            lines.append("- Decision \(item): a sentence long enough to wrap at the reading "
                         + "measure once or twice, so every item has real height of its own.")
        }
        lines += ["", "After the list.", ""]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-list-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MarkdownDocument(url: url)
    }

    private func paneWithLongList(items: Int = 60) throws -> (NativeDocumentView, Int) {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: paneWidth(forColumns: 2), height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try longListDocument(items: items), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let list = try XCTUnwrap(view.built?.components.firstIndex {
            if case .listItem = $0.kind { return true } else { return false }
        })
        return (view, list)
    }

    /// The pages tile the list exactly: every item on exactly one page, in order.
    func testATallListIsPaginatedAtItemBoundaries() throws {
        let (view, list) = try paneWithLongList()
        let stack = view.stackView
        XCTAssertFalse(stack.spans(component: list), "the list should paginate, not span")
        XCTAssertGreaterThan(stack.placementCount(ofComponent: list), 1,
                             "the fixture list should need several pages")

        let component = try XCTUnwrap(view.built).components[list]
        let parts = try XCTUnwrap(component.parts, "a list of several items should carry parts")
        guard case .text(let attributed) = component.content else { return XCTFail("not text") }
        // The parts tile the component's text, so the slices lose nothing between them.
        XCTAssertEqual(parts.first?.location, 0)
        for (part, next) in zip(parts, parts.dropFirst()) {
            XCTAssertEqual(NSMaxRange(part), next.location, "parts leave a gap or overlap")
        }
        XCTAssertEqual(parts.last.map(NSMaxRange), attributed.length)

        let ranges = stack.rowRanges(ofComponent: list)
        var expected = 0
        for range in ranges {
            XCTAssertEqual(range.lowerBound, expected, "pages skip or repeat items: \(ranges)")
            XCTAssertGreaterThan(range.count, 0, "an empty page of list")
            expected = range.upperBound
        }
        XCTAssertEqual(expected, parts.count, "the last items never got a page")
    }

    /// No page of the list is taller than the page it sits on, and none sits on another
    /// component.
    func testSplitListPagesFitTheirColumn() throws {
        let (view, list) = try paneWithLongList()
        let stack = view.stackView
        let target = stack.spreadHeight
        XCTAssertGreaterThan(target, 0)
        for frame in stack.frames(ofComponent: list) {
            XCTAssertLessThanOrEqual(frame.height, target + 1,
                                     "a page of the list overflows the column")
        }
        try assertNoComponentOverlaps(in: view)
    }

    /// A split list starts in the room that is left, not on the next page — same rule as the
    /// table, for the same reason.
    func testASplitListStartsInTheRoomThatIsLeft() throws {
        let (view, list) = try paneWithLongList()
        let stack = view.stackView
        XCTAssertGreaterThan(list, 0, "the fixture should have content before the list")
        let heading = stack.frame(ofComponent: list - 1)
        let first = stack.frame(ofComponent: list)
        XCTAssertEqual(stack.spreadIndex(ofComponent: list),
                       stack.spreadIndex(ofComponent: list - 1),
                       "the list should start on the heading's page")
        XCTAssertGreaterThan(first.minY, heading.minY,
                             "the first page of the list should sit under its heading")
    }

    /// A single column is a single page, so nothing is split there.
    func testSingleColumnDoesNotSplitLists() throws {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: paneWidth(forColumns: 1), height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try longListDocument(items: 60), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let list = try XCTUnwrap(view.built?.components.firstIndex {
            if case .listItem = $0.kind { return true } else { return false }
        })
        XCTAssertEqual(view.stackView.columnCount, 1)
        XCTAssertEqual(view.stackView.placementCount(ofComponent: list), 1)
    }
}
