import AppKit
import XCTest
@testable import FolioKit

/// What one scroll event looks at.
///
/// Every scroll event asks the stack four questions — which placements need views, which
/// components are on screen, which component the reading line has reached, and where the reader
/// is — and each of them used to walk every placement in the document. On a book that walk *was*
/// the cost of a scroll: on a 7,700-component document the viewport handler ran 7ms an event,
/// every frame, whether or not anything on screen had changed, and the tracer counted a hitch
/// on one frame in six. The lookups now search the spreads (or the placements' tops, in a single
/// column) for the band a viewport covers. These tests pin that mechanism the way this project
/// pins measuring: by counting what a lookup examines, and by checking its answers against a
/// walk over the lot.
final class ScrollLookupTests: XCTestCase {

    private let metrics = testMetrics

    /// A document long enough that a walk over it is visibly not a screenful. `paragraphs`
    /// only lengthens the tail: two documents share their first `min` paragraphs exactly, so
    /// the same scroll offset in each shows the same content.
    private func longDocument(paragraphs: Int) throws -> MarkdownDocument {
        var lines = ["---", "title: Long", "author: Test", "---", "", "# Long", ""]
        for index in 1...paragraphs {
            if index % 15 == 0 { lines += ["## Section \(index / 15)", ""] }
            lines += ["Paragraph \(index) with enough words to wrap at a normal measure and take "
                        + "more than one line of the reading column.", ""]
            if index % 40 == 0 {
                lines += ["| Item | Page |", "| --- | --- |", "| One | 1 |", "| Two | 2 |", ""]
            }
            if index % 23 == 0 {
                lines += ["- item one of a list", "- item two of a list", "- item three", ""]
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-lookup-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MarkdownDocument(url: url)
    }

    /// The window is returned so the caller keeps it alive.
    private func pane(columns: Int, paragraphs: Int = 600) throws
        -> (NativeDocumentView, NSWindow) {
        let view = NativeDocumentView(metrics: metrics)
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: paneWidth(forColumns: columns, metrics: metrics),
                            height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try longDocument(paragraphs: paragraphs), metrics: metrics)
        settle(view)
        XCTAssertEqual(view.stackView.columnCount, columns)
        return (view, window)
    }

    private func settle(_ view: NSView, turns: Int = 12) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// One scroll event, as the clip view delivers it, and the display pass after it.
    private func scroll(_ view: NativeDocumentView, to y: CGFloat) {
        view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        for _ in 0..<4 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    /// Every y a probe might be asked about: above the document, through it, and past its end.
    private func probeOffsets(in stack: DocumentStackView) -> [CGFloat] {
        Array(stride(from: -100, through: stack.contentHeight + 200, by: 137))
    }

    // MARK: What an event examines

    /// The placements a scroll event looks at are the ones near the viewport — so the count is
    /// the same whether the document is long or twice as long.
    private func placementsExamined(byOneEventIn view: NativeDocumentView) -> Int {
        // The outline's callbacks are wired, as they are under the window, so the event runs
        // the visible-sections report and the heading probe as well as the vend.
        view.onVisibleSectionsChange = { _ in }
        view.onHeadingChange = { _ in }
        scroll(view, to: 2000)
        let before = view.stackView.placementsVisited
        scroll(view, to: 2060)
        return view.stackView.placementsVisited - before
    }

    func testAScrollEventExaminesAScreenfulNotTheDocumentInASpread() throws {
        let (short, shortWindow) = try pane(columns: 2, paragraphs: 400)
        let (long, longWindow) = try pane(columns: 2, paragraphs: 1200)
        withExtendedLifetime((shortWindow, longWindow)) {}
        let shortPlacements = short.stackView.placementsForTests.count
        let longPlacements = long.stackView.placementsForTests.count
        XCTAssertGreaterThan(longPlacements, shortPlacements * 2,
                             "the long document is not long enough to tell a walk from a search")

        let onShort = placementsExamined(byOneEventIn: short)
        let onLong = placementsExamined(byOneEventIn: long)
        XCTAssertGreaterThan(onShort, 0, "the event examined nothing at all")
        XCTAssertLessThan(onShort, shortPlacements / 2,
                          "one scroll event examined \(onShort) of \(shortPlacements) placements")
        // The same offset shows the same content in both, so the only difference a longer
        // document may make is a few more steps of the searches.
        XCTAssertLessThanOrEqual(onLong, onShort + 40,
                                 "the event's cost grew with the document: \(onShort) placements "
                                     + "on the short one, \(onLong) on the long one")
    }

    func testAScrollEventExaminesAScreenfulNotTheDocumentInASingleColumn() throws {
        let (short, shortWindow) = try pane(columns: 1, paragraphs: 400)
        let (long, longWindow) = try pane(columns: 1, paragraphs: 1200)
        withExtendedLifetime((shortWindow, longWindow)) {}
        let shortPlacements = short.stackView.placementsForTests.count

        let onShort = placementsExamined(byOneEventIn: short)
        let onLong = placementsExamined(byOneEventIn: long)
        XCTAssertGreaterThan(onShort, 0, "the event examined nothing at all")
        XCTAssertLessThan(onShort, shortPlacements / 2,
                          "one scroll event examined \(onShort) of \(shortPlacements) placements")
        XCTAssertLessThanOrEqual(onLong, onShort + 40,
                                 "the event's cost grew with the document: \(onShort) placements "
                                     + "on the short one, \(onLong) on the long one")
    }

    // MARK: The answers

    /// The set of components a viewport rect intersects is exactly what a walk over every
    /// placement finds — in both layouts, for viewports everywhere in the document.
    func testTheComponentsOnScreenMatchAWalkOverEveryPlacement() throws {
        for columns in [1, 2] {
            let (view, window) = try pane(columns: columns)
            withExtendedLifetime(window) {}
            let stack = view.stackView
            let all = stack.placementsForTests
            let height = view.scrollView.contentView.bounds.height
            for y in probeOffsets(in: stack) {
                let viewport = NSRect(x: 0, y: y, width: stack.bounds.width, height: height)
                let expected = Set(all.filter { $0.frame.intersects(viewport) }
                                       .map { $0.component })
                XCTAssertEqual(stack.components(intersecting: viewport), expected,
                               "at y \(y) in \(columns) column(s)")
            }
        }
    }

    /// The reading-line probe answers as the walk did: in a single column, the last placement
    /// starting at or above the line; in a spread, the spread's reading order taken as far as
    /// the line has travelled down the spread.
    func testTheReadingLineProbeMatchesAWalkOverEveryPlacement() throws {
        let (single, singleWindow) = try pane(columns: 1)
        withExtendedLifetime(singleWindow) {}
        let singleStack = single.stackView
        let singlePlacements = singleStack.placementsForTests
        for y in probeOffsets(in: singleStack) {
            let expected = singlePlacements.last { $0.frame.minY <= y }?.component ?? 0
            XCTAssertEqual(singleStack.componentIndex(atY: y), expected, "at y \(y)")
        }

        let (spread, spreadWindow) = try pane(columns: 2)
        withExtendedLifetime(spreadWindow) {}
        let stack = spread.stackView
        let all = stack.placementsForTests
        for y in probeOffsets(in: stack) {
            let page = (0..<stack.spreadCount).last { stack.spreadFrame(at: $0).minY <= y } ?? 0
            let onPage = all.filter { $0.spread == page }
            let frame = stack.spreadFrame(at: page)
            let progress = min(1, max(0, (y - frame.minY) / max(1, frame.height)))
            let step = min(onPage.count - 1, Int(progress * CGFloat(onPage.count)))
            XCTAssertEqual(stack.componentIndex(atY: y), onPage[step].component, "at y \(y)")
        }
    }

    /// After a scroll the views in the stack are exactly the placements within the overscan of
    /// the viewport — no more, none missing — wherever the viewport lands.
    func testVendingBuildsExactlyTheViewsAWalkWouldPick() throws {
        for columns in [1, 2] {
            let (view, window) = try pane(columns: columns)
            withExtendedLifetime(window) {}
            let stack = view.stackView
            let all = stack.placementsForTests
            let maxY = stack.frame.height - view.scrollView.contentView.bounds.height
            for y in [0, 1500, 4200, maxY / 2, maxY - 300, maxY] {
                scroll(view, to: y)
                let wanted = stack.visibleRect.insetBy(dx: 0, dy: -DocumentStackView.overscan)
                let expected = Set(all.filter {
                    $0.frame.maxY >= wanted.minY && $0.frame.minY <= wanted.maxY
                }.map { NSStringFromRect($0.frame) })
                let actual = Set(stack.subviews.map { NSStringFromRect($0.frame) })
                XCTAssertEqual(actual, expected, "at y \(y) in \(columns) column(s)")
            }
        }
    }
}
