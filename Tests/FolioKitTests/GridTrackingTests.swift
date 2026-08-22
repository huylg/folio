import AppKit
import XCTest
@testable import FolioKit

/// Outline tracking in the two-column layout.
///
/// A spread has no single reading position: both columns are on screen at once and share the same
/// y range. Probing only the left column, as this used to, meant a heading in the right-hand column
/// became current only when the *next* spread arrived — the outline lagged a page behind the page,
/// and the sections in between never lit up at all.
final class GridTrackingTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func sampleDocument() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    private func gridPane() throws -> (NativeDocumentView, MarkdownDocument) {
        let document = try sampleDocument()
        let view = NativeDocumentView(metrics: metrics)
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: paneWidth(forColumns: 2, metrics: metrics),
                            height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: document, metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(view.stackView.columnCount, 2, "the pane should be in two columns")
        return (view, document)
    }

    private func scroll(_ view: NativeDocumentView, to y: CGFloat) {
        view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }

    /// Scrolling a spread through the viewport walks its whole reading order — both columns —
    /// exactly once, in order.
    func testTrackingCoversEveryHeadingInGridMode() throws {
        let (view, document) = try gridPane()
        var reported: [Int] = []
        view.onHeadingChange = { reported.append($0) }

        let maxY = view.stackView.frame.height - view.scrollView.contentView.bounds.height
        for y in stride(from: 0, through: maxY, by: 8) { scroll(view, to: y) }

        XCTAssertEqual(reported, Array(1..<document.outline.count),
                       "grid tracking skipped or repeated a section: "
                           + "\(reported.map { document.outline[$0].title })")
    }

    /// And never moves backwards on the way down.
    func testTrackingIsMonotonicInGridMode() throws {
        let (view, _) = try gridPane()
        var reported: [Int] = []
        view.onHeadingChange = { reported.append($0) }

        let maxY = view.stackView.frame.height - view.scrollView.contentView.bounds.height
        for y in stride(from: 0, through: maxY, by: 8) { scroll(view, to: y) }

        for (a, b) in zip(reported, reported.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "the outline moved backwards: \(reported)")
        }
    }

    /// Clicking a row lands on that row here too, and scrolling on afterwards keeps tracking.
    func testClickingThenScrollingKeepsTracking() throws {
        let (view, document) = try gridPane()
        var current = -1
        view.onHeadingChange = { current = $0 }

        let target = try XCTUnwrap(document.outline.firstIndex { $0.title.hasPrefix("2.1") })
        view.scroll(toAnchor: document.outline[target].anchor)
        XCTAssertEqual(current, target, "the click did not land")

        let landed = view.scrollView.contentView.bounds.minY
        for step in 1...12 { scroll(view, to: landed + CGFloat(step) * 60) }
        XCTAssertGreaterThan(current, target,
                             "tracking stopped following after the click")
    }

    /// The pin has to release even when navigation could not park its target at the top.
    ///
    /// Near the end of a document the scroll clamps, so the heading never reaches the top edge. A
    /// pin waiting for it to get there was never released, and the outline stayed stuck on the
    /// clicked section for every scroll that is not a trackpad gesture — keyboard paging included.
    func testPinReleasesEvenWhenTheDestinationIsClamped() throws {
        let (view, document) = try gridPane()
        let last = document.outline.count - 1
        view.scroll(toAnchor: document.outline[last].anchor)
        for _ in 0..<6 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }

        var current = -1
        view.onHeadingChange = { current = $0 }
        // Back to the top, the way a keyboard shortcut would — no live-scroll notification.
        scroll(view, to: 0)
        for _ in 0..<6 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTAssertNotEqual(current, -1, "the outline never updated after leaving the clicked section")
        XCTAssertLessThan(current, last, "the outline stayed pinned to the click")
    }
}
