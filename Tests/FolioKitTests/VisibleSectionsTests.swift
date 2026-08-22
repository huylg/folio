import AppKit
import XCTest
@testable import FolioKit

/// Marking every section on screen, not just one.
///
/// A spread routinely shows three or four sections at once. Highlighting one of them tells the
/// reader nothing about how far the page reaches — the rest could belong to that section or to the
/// next three.
final class VisibleSectionsTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func document() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    private func pane(width: CGFloat) throws -> (NativeDocumentView, MarkdownDocument) {
        let document = try self.document()
        let view = NativeDocumentView(metrics: metrics)
        view.animatesNavigation = false
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
        return (view, document)
    }

    private func scroll(_ view: NativeDocumentView, to y: CGFloat) {
        view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        for _ in 0..<4 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    func testAGridSpreadReportsSeveralSections() throws {
        let (view, _) = try pane(width: paneWidth(forColumns: 2, metrics: metrics))
        XCTAssertEqual(view.stackView.columnCount, 2)

        var visible: Set<Int> = []
        var current = -1
        view.onVisibleSectionsChange = { visible = $0 }
        view.onHeadingChange = { current = $0 }
        scroll(view, to: view.stackView.spreadFrame(at: 1).minY)

        XCTAssertGreaterThan(visible.count, 1,
                             "a spread showing several sections reported only \(visible)")
        XCTAssertTrue(visible.contains(current),
                      "the current section \(current) is not in the visible group \(visible)")
    }

    /// In a single column the sections on screen are consecutive: content runs down the page, so
    /// a screenful cannot show 1 and 4 without 2 and 3.
    ///
    /// Deliberately *not* asserted for a spread. There, a short section can sit entirely in the top
    /// of the right-hand column while the bottom of the left column and the next page's top are
    /// both on screen — so the group legitimately has a gap.
    func testTheVisibleGroupIsContiguousInASingleColumn() throws {
        let (view, _) = try pane(width: paneWidth(forColumns: 1, metrics: metrics))
        XCTAssertEqual(view.stackView.columnCount, 1)
        var visible: Set<Int> = []
        view.onVisibleSectionsChange = { visible = $0 }

        let maxY = view.stackView.frame.height - 700
        for y in stride(from: 0, through: maxY, by: 60) {
            scroll(view, to: y)
            guard let low = visible.min(), let high = visible.max() else { continue }
            XCTAssertEqual(visible.count, high - low + 1,
                           "the group has a hole in it: \(visible.sorted())")
        }
    }

    /// Whatever is reported, every section in the group really does have content on screen.
    func testEverySectionInTheGroupIsOnScreen() throws {
        let (view, document) = try pane(width: paneWidth(forColumns: 2, metrics: metrics))
        var visible: Set<Int> = []
        view.onVisibleSectionsChange = { visible = $0 }

        let built = try XCTUnwrap(view.built)
        let maxY = view.stackView.frame.height - 700
        for y in stride(from: 0, through: maxY, by: 90) {
            scroll(view, to: y)
            let viewport = view.scrollView.contentView.bounds
            let onScreen = view.stackView.components(intersecting: viewport)
            for outlineIndex in visible {
                let heading = try XCTUnwrap(built.headings.firstIndex {
                    $0.outlineIndex == outlineIndex
                })
                let range = built.headings[heading].range
                let start = try XCTUnwrap(built.componentIndex(containing: range.location))
                let end = built.headings.indices.contains(heading + 1)
                    ? (built.componentIndex(containing: built.headings[heading + 1].range.location)
                        ?? built.components.count) - 1
                    : built.components.count - 1
                XCTAssertTrue((start...max(start, end)).contains { onScreen.contains($0) },
                              "'\(document.outline[outlineIndex].title)' was reported visible "
                                  + "but none of its components are on screen")
            }
        }
    }

    /// It follows the reader.
    func testTheGroupAdvancesWithScrolling() throws {
        let (view, _) = try pane(width: paneWidth(forColumns: 2, metrics: metrics))
        var visible: Set<Int> = []
        view.onVisibleSectionsChange = { visible = $0 }

        scroll(view, to: 0)
        let atTop = visible
        scroll(view, to: view.stackView.frame.height - 700)
        XCTAssertNotEqual(visible, atTop, "the group never changed")
        XCTAssertGreaterThan(visible.min() ?? 0, atTop.min() ?? 0,
                             "the group did not move forward")
    }

    /// A single column shows several sections too, and gets the same treatment.
    func testSingleColumnAlsoReportsGroups() throws {
        let (view, _) = try pane(width: paneWidth(forColumns: 1, metrics: metrics))
        XCTAssertEqual(view.stackView.columnCount, 1)
        var visible: Set<Int> = []
        view.onVisibleSectionsChange = { visible = $0 }
        scroll(view, to: 600)
        XCTAssertGreaterThan(visible.count, 1, "reported only \(visible)")
    }

    /// The sidebar shows the group as a weaker marking, with the current row's pill on top of it.
    func testTheSidebarMarksTheGroup() throws {
        let document = try self.document()
        let outline = OutlineViewController()
        outline.view.frame = NSRect(x: 0, y: 0, width: 230, height: 500)
        let window = TestWindow(contentRect: outline.view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = outline.view
        window.orderBack(nil)
        outline.update(document: document)
        outline.view.layoutSubtreeIfNeeded()

        let restore = OutlineIndicatorView.moveDuration
        OutlineIndicatorView.moveDuration = 0
        addTeardownBlock { OutlineIndicatorView.moveDuration = restore }
        outline.highlight(index: 5)
        outline.markVisible([4, 5, 6, 7])
        outline.view.layoutSubtreeIfNeeded()

        guard let table = (outline.view.subviews.first as? NSScrollView)?
            .documentView as? OutlineTableView
        else { return XCTFail("no table") }

        // The block is the outline's whole state: one shape over the sections on screen.
        waitUntil { table.groupRows != nil }
        XCTAssertEqual(table.groupRows, 4...7, "the block does not span the group")

        let blocks = table.subviews.compactMap { $0 as? OutlineIndicatorView }
        XCTAssertEqual(blocks.count, 1, "the group is one block, not several")
        let block = try XCTUnwrap(blocks.first)
        let expected = table.rect(ofRow: 4).union(table.rect(ofRow: 7))
        XCTAssertEqual(block.frame.minY, expected.minY + OutlineIndicatorView.inset.height,
                       accuracy: 1)
        XCTAssertEqual(block.frame.maxY, expected.maxY - OutlineIndicatorView.inset.height,
                       accuracy: 1)
        XCTAssertNil(block.hitTest(NSPoint(x: block.bounds.midX, y: block.bounds.midY)),
                     "the block must not swallow clicks")

    }

    /// The block follows the sidebar's width.
    ///
    /// It is positioned from the rows it spans when the page changes, and a sidebar dragged wider
    /// afterwards left it at the old width — a marking that no longer reached the rows it marked.
    func testTheBlockFollowsTheSidebarsWidth() throws {
        let (outline, document) = (OutlineViewController(), try document())
        outline.view.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let window = TestWindow(contentRect: outline.view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = outline.view
        window.orderBack(nil)
        outline.update(document: document)
        outline.view.layoutSubtreeIfNeeded()

        let restore = OutlineIndicatorView.moveDuration
        OutlineIndicatorView.moveDuration = 0
        addTeardownBlock { OutlineIndicatorView.moveDuration = restore }
        outline.markVisible([2, 3])
        outline.view.layoutSubtreeIfNeeded()

        guard let table = (outline.view.subviews.first as? NSScrollView)?
            .documentView as? OutlineTableView
        else { return XCTFail("no table") }
        XCTAssertTrue(waitUntil { table.groupRows != nil })
        let block = try XCTUnwrap(table.subviews.compactMap { $0 as? OutlineIndicatorView }.first)
        let before = block.frame.width

        window.setContentSize(NSSize(width: 360, height: 600))
        outline.view.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        outline.view.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(block.frame.width, before + 50,
                             "the block kept the width the sidebar used to have")
        XCTAssertEqual(block.frame.width,
                       table.bounds.width - OutlineIndicatorView.inset.width * 2, accuracy: 1,
                       "the block does not span the table")
    }

    /// Scrolling moves the block, and the move is animated.
    ///
    /// It was not, and for a reason worth keeping written down: a block that draws itself has its
    /// frame animated by AppKit's own timer, and that timer does not run while the reading pane is
    /// being scrolled. So the one move the reader watches most — the block following them down the
    /// page — was the one move that jumped.
    func testTheBlockSlidesWhenScrollingMovesIt() throws {
        let (outline, document) = (OutlineViewController(), try document())
        outline.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        let window = TestWindow(contentRect: outline.view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = outline.view
        window.orderBack(nil)
        outline.update(document: document)
        outline.view.layoutSubtreeIfNeeded()

        guard let table = (outline.view.subviews.first as? NSScrollView)?
            .documentView as? OutlineTableView
        else { return XCTFail("no table") }

        outline.markVisible([1, 2])
        XCTAssertTrue(waitUntil { table.groupRows == 1...2 })
        let block = try XCTUnwrap(table.subviews.compactMap { $0 as? OutlineIndicatorView }.first)
        // Core Animation drives the move, which is what survives a scroll's event tracking.
        XCTAssertTrue(block.wantsLayer, "the block is drawn, so its move cannot outlive a scroll")

        // The page moves on, as it does under a scroll.
        outline.markVisible([3, 4])
        XCTAssertTrue(waitUntil { table.groupRows == 3...4 })
        XCTAssertEqual(table.lastMoveDuration, OutlineIndicatorView.moveDuration, accuracy: 0.001,
                       "the block jumped to the new sections instead of sliding")
    }

    /// Coming and going are animated too, not just travelling.
    ///
    /// Appearing and disappearing shared the move's duration, and a move with nowhere to come
    /// from is given no duration at all — so the block popped into being and vanished, which is
    /// the pair of moments the reader is most likely to catch.
    func testTheBlockFadesInAndOut() throws {
        let (outline, document) = (OutlineViewController(), try document())
        outline.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        let window = TestWindow(contentRect: outline.view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = outline.view
        window.orderBack(nil)
        outline.update(document: document)
        outline.view.layoutSubtreeIfNeeded()

        guard let table = (outline.view.subviews.first as? NSScrollView)?
            .documentView as? OutlineTableView
        else { return XCTFail("no table") }

        // Arriving: no frame to interpolate, so the fade is the whole animation.
        outline.markVisible([1, 2])
        XCTAssertTrue(waitUntil { table.groupRows == 1...2 })
        XCTAssertEqual(table.lastFadeDuration, OutlineIndicatorView.fadeDuration, accuracy: 0.001,
                       "the block popped into being")
        XCTAssertEqual(table.lastMoveDuration, 0, accuracy: 0.001,
                       "a block appearing has nowhere to travel from")

        // Staying put while the page moves: the fade has nothing to do.
        outline.markVisible([3, 4])
        XCTAssertTrue(waitUntil { table.groupRows == 3...4 })
        XCTAssertEqual(table.lastFadeDuration, 0, accuracy: 0.001,
                       "a block that is already on screen should not be faded again")

        // Leaving: nothing on the page belongs to a section the outline knows about.
        outline.markVisible([])
        XCTAssertTrue(waitUntil { table.groupRows == nil })
        XCTAssertEqual(table.lastFadeDuration, OutlineIndicatorView.fadeDuration, accuracy: 0.001,
                       "the block vanished instead of fading out")
    }
}
