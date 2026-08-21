import AppKit
import XCTest
@testable import FolioKit

/// Regression cover for the reading pane not scrolling at all.
///
/// `NSTextView.maxSize` defaults to the view's initial frame, and `isVerticallyResizable` only
/// lets the view grow *up to* that. So the text view stayed at its starting height, the scroll
/// view's document view never exceeded its clip view, and the scroller stayed hidden — with a
/// 2500pt document showing only its first screen and no way to reach the rest.
final class ScrollingTests: XCTestCase {

    private func sampleDocument() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func settle(_ view: NSView, turns: Int = 12) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// A window is required: attachment views are vended by the viewport layout controller,
    /// which only runs for a text view inside one.
    private func makeReadingPane() throws -> NativeDocumentView {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try sampleDocument(), metrics: metrics)
        settle(view)
        return view
    }

    func testDocumentIsTallerThanTheViewport() throws {
        let view = try makeReadingPane()
        let documentView = try XCTUnwrap(view.scrollView.documentView)
        XCTAssertGreaterThan(documentView.frame.height,
                             view.scrollView.contentView.bounds.height,
                             "nothing to scroll: the text view did not grow past its frame")
    }

    func testVerticalScrollerIsShown() throws {
        let view = try makeReadingPane()
        let scroller = try XCTUnwrap(view.scrollView.verticalScroller)
        XCTAssertFalse(scroller.isHidden, "the scroller stayed hidden")
    }

    func testScrollingMovesTheViewport() throws {
        let view = try makeReadingPane()
        let scrollView = view.scrollView
        XCTAssertEqual(scrollView.documentVisibleRect.minY, 0, accuracy: 1)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(scrollView.documentVisibleRect.minY, 400, accuracy: 1,
                       "the viewport did not move")
    }

    /// The stack has to be as tall as its last component, or the end of the document cannot be
    /// scrolled to. The previous pane grew to its content over several passes, because TextKit
    /// reports a height only for what it has laid out; the stack measures everything up front.
    func testTheEndOfTheDocumentIsReachable() throws {
        let view = try makeReadingPane()
        settle(view)

        let built = try XCTUnwrap(view.built)
        let last = view.stackView.frame(ofComponent: built.components.count - 1)
        let documentView = try XCTUnwrap(view.scrollView.documentView)
        XCTAssertGreaterThanOrEqual(documentView.frame.height, last.maxY,
                                    "the document view is shorter than its content, so the end "
                                        + "of the document cannot be scrolled to")
    }

}

/// The outline follows the reading position, including at the very end of the document.
final class HeadingTrackingTests: XCTestCase {

    private func sampleDocument() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    private func makePane() throws -> (NativeDocumentView, [Int]) {
        let metrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                      lineWidth: .comfortable, density: .airy)
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)

        var reported: [Int] = []
        view.onHeadingChange = { reported.append($0) }
        view.render(document: try sampleDocument(), metrics: metrics)
        settle(view)
        return (view, reported)
    }

    private func settle(_ view: NSView, turns: Int = 12) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
    }

    private func scroll(_ view: NativeDocumentView, to y: CGFloat, turns: Int = 4) {
        view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        settle(view, turns: turns)
    }

    /// The bug from the screenshot: scrolled fully to the bottom, the outline still pointed at a
    /// heading several sections back, because the probe sat 80pt below the viewport's top and
    /// every trailing heading fell below it.
    func testTheLastHeadingBecomesCurrentAtTheEnd() throws {
        let (view, _) = try makePane()
        var latest = -1
        view.onHeadingChange = { latest = $0 }

        let documentHeight = try XCTUnwrap(view.scrollView.documentView).frame.height
        let maxOffset = documentHeight - view.scrollView.contentView.bounds.height
        XCTAssertGreaterThan(maxOffset, 0, "document is not scrollable")
        scroll(view, to: maxOffset)

        let outlineCount = try sampleDocument().outline.count
        XCTAssertEqual(latest, outlineCount - 1,
                       "at the end of the document the outline should be on its last heading")
    }

    func testTheFirstHeadingIsCurrentAtTheTop() throws {
        let (view, _) = try makePane()
        var latest = -1
        view.onHeadingChange = { latest = $0 }
        scroll(view, to: 400)
        scroll(view, to: 0)
        XCTAssertEqual(latest, 0, "at the top the outline should be on the first heading")
    }

    /// Scrolling forward must never move the outline backwards.
    ///
    /// The steps are small on purpose. At tenth-of-a-document jumps this passed while the
    /// outline was visibly flashing backwards: it reported "2 Method", then "1.2 Contributions"
    /// about 70pt later, then "2 Method" again. Two probes disagreed — a band at the top of the
    /// viewport, which won, against a reading line that slid hundreds of points ahead of it —
    /// and only a step finer than the distance between them could see it.
    func testTrackingIsMonotonicWhileScrollingDown() throws {
        let (view, _) = try makePane()
        var reported: [Int] = []
        view.onHeadingChange = { reported.append($0) }

        let documentHeight = try XCTUnwrap(view.scrollView.documentView).frame.height
        let maxOffset = documentHeight - view.scrollView.contentView.bounds.height
        for y in stride(from: 0, through: maxOffset, by: 6) {
            scroll(view, to: y, turns: 1)
        }

        XCTAssertFalse(reported.isEmpty, "no heading changes were reported")
        for (a, b) in zip(reported, reported.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "the outline moved backwards while scrolling down: "
                                        + "\(reported)")
        }
        // And nothing is skipped or repeated: each section becomes current exactly once, which
        // is the other way a misplaced probe shows up.
        let outlineCount = try sampleDocument().outline.count
        XCTAssertEqual(reported, Array(1..<outlineCount),
                       "the outline skipped or repeated a section")
    }
}
