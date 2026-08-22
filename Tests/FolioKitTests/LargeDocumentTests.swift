import AppKit
import XCTest
@testable import FolioKit

/// What a book-sized document costs.
///
/// Measuring is the expensive thing the stack does — linear in the document, and a converted book
/// runs to thousands of components. Reflowing on every size change meant a live resize wedged the
/// main thread for the whole drag: on a 2,283-component document a *one point* resize measured
/// everything again, 535ms a time, so dragging a window edge froze the app for tens of seconds
/// and it had to be force-quit. These tests pin the mechanisms that fixed it, rather than timings,
/// which would be flaky.
final class LargeDocumentTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    /// A document with enough components that re-measuring is expensive.
    private func largeDocument() throws -> MarkdownDocument {
        var lines = ["---", "title: Large", "author: Test", "---", "", "# Large", ""]
        for index in 1...400 {
            if index % 20 == 0 { lines += ["## Chapter \(index / 20)", ""] }
            lines += ["Paragraph \(index) with enough words to wrap at a normal measure and take "
                        + "more than one line of the reading column.", ""]
            if index % 25 == 0 {
                lines += ["| Item | Page |", "| --- | --- |", "| One | 1 |", "| Two | 2 |", ""]
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-large-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MarkdownDocument(url: url)
    }

    /// The narrowest pane that holds a two-column spread. A property rather than a default
    /// argument, which cannot read `metrics`.
    private var spreadWidth: CGFloat { paneWidth(forColumns: 2, metrics: metrics) }

    private func pane(width: CGFloat? = nil) throws -> (NativeDocumentView, NSWindow) {
        let width = width ?? spreadWidth
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try largeDocument(), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        settle(view)
        return (view, window)
    }

    private func settle(_ view: NSView, turns: Int = 10) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// Nothing is measured while the reader is dragging the window's edge.
    func testLiveResizeDoesNotReflow() throws {
        let (view, window) = try pane()
        let before = view.stackView.measuredComponents
        XCTAssertGreaterThan(before, 100, "the document should have been measured once on open")

        view.viewWillStartLiveResize()
        for width in stride(from: spreadWidth, through: spreadWidth + 60, by: 4.0) {
            window.setContentSize(NSSize(width: width, height: 800))
            view.layoutSubtreeIfNeeded()
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        XCTAssertEqual(view.stackView.measuredComponents, before,
                       "a live resize re-measured the document, which freezes the app on a book")

        view.viewDidEndLiveResize()
        settle(view)
        XCTAssertGreaterThanOrEqual(view.stackView.measuredComponents, before,
                                    "the drag never reflowed at all")
    }

    /// In a spread the column is the reading measure whatever the window's width, so a resize that
    /// keeps the column width must not measure anything again.
    func testResizeThatKeepsTheColumnWidthMeasuresNothing() throws {
        let (view, window) = try pane(width: spreadWidth)
        XCTAssertEqual(view.stackView.columnCount, 2)
        let before = view.stackView.measuredComponents

        window.setContentSize(NSSize(width: spreadWidth + 60, height: 800))
        view.layoutSubtreeIfNeeded()
        settle(view)

        XCTAssertEqual(view.stackView.columnCount, 2)
        XCTAssertEqual(view.stackView.measuredComponents, before,
                       "the size cache was thrown away and every component re-measured "
                           + "to the same height")
    }

    /// Each component is measured once per width, not once per layout pass.
    func testScrollingDoesNotMeasure() throws {
        let (view, _) = try pane()
        let before = view.stackView.measuredComponents

        for step in stride(from: 0.0, through: 4000.0, by: 250.0) {
            view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: step))
            view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
        XCTAssertEqual(view.stackView.measuredComponents, before,
                       "scrolling re-measured components")
    }

    /// Only a handful of views exist however long the document is.
    func testViewCountStaysBounded() throws {
        let (view, _) = try pane()
        let components = try XCTUnwrap(view.built).components.count
        XCTAssertGreaterThan(components, 400, "fixture is not large enough to be a test")

        for step in stride(from: 0.0, through: 6000.0, by: 300.0) {
            view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: step))
            view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
            XCTAssertLessThan(view.stackView.subviews.count, 80,
                              "the stack is building far more views than the viewport needs")
        }
    }
}

/// A sidebar toggle changes the pane's width over a couple of hundred milliseconds. Reflowing on
/// each frame of that re-paginated the document ten times and moved everything twice per frame —
/// the "clunky" toggle. The stack follows the width immediately, and reflows once, at the end.
extension LargeDocumentTests {

    func testAnAnimatedWidthChangeReflowsOnce() throws {
        let (view, window) = try pane(width: spreadWidth)
        let before = view.stackView.measuredComponents
        let startWidth = view.stackView.frame.width

        // A sidebar collapsing: the pane widens over ~15 frames.
        for step in 1...15 {
            window.setContentSize(NSSize(width: spreadWidth + CGFloat(step) * 20, height: 800))
            view.layoutSubtreeIfNeeded()
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.004))
            // The stack keeps up with the pane the whole way, so the columns glide rather than
            // waiting for the end and jumping.
            XCTAssertEqual(view.stackView.frame.width, view.bounds.width, accuracy: 1,
                           "the stack fell behind the pane at frame \(step)")
        }
        XCTAssertGreaterThan(view.stackView.frame.width, startWidth)

        let duringAnimation = view.stackView.measuredComponents
        XCTAssertEqual(duringAnimation, before,
                       "the document was re-measured mid-animation")

        // And it settles shortly after the last change.
        let settled = view.settledLayoutForTests
        XCTAssertTrue(waitUntil { view.stackView.columnCount == settled.columns },
                      "the layout never settled after the animation")
    }
}
