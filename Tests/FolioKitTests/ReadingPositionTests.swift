import AppKit
import XCTest
@testable import FolioKit

/// Where the reader is, across a change of layout.
///
/// One column to two and back is the case that gave this away: the anchor a layout change restores
/// used to be re-read from the viewport each time, and in a spread the viewport's top can only name
/// the top of a page — so each change quantised the position to a page start and the round trip
/// returned the reader a little earlier than they had been.
final class ReadingPositionTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func pane(width: CGFloat) throws -> (NativeDocumentView, NSWindow) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        let view = NativeDocumentView(metrics: metrics)
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try MarkdownDocument(url: url), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        settle()
        return (view, window)
    }

    private func settle(_ seconds: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func resize(_ window: NSWindow, _ view: NSView, to width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 700))
        view.layoutSubtreeIfNeeded()
        settle()
    }

    /// Scrolls the way the reader does, so the pane treats the position as theirs.
    private func readerScrolls(_ view: NativeDocumentView, toY y: CGFloat) {
        view.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        settle(0.1)
    }

    /// One column, to a spread, and back: the reader ends up where they started.
    func testAColumnRoundTripKeepsThePosition() throws {
        let (view, window) = try pane(width: paneWidth(forColumns: 1, metrics: metrics))
        XCTAssertEqual(view.stackView.columnCount, 1)

        readerScrolls(view, toY: 1400)
        let anchor = view.captureScrollAnchor()
        XCTAssertGreaterThan(anchor.component, 0, "the scroll should have moved off the title")

        resize(window, view, to: paneWidth(forColumns: 2, metrics: metrics))
        XCTAssertEqual(view.stackView.columnCount, 2, "the pane should be a spread at 1500pt")
        resize(window, view, to: 900)
        XCTAssertEqual(view.stackView.columnCount, 1)

        XCTAssertEqual(view.captureScrollAnchor().component, anchor.component,
                       "the round trip landed on a different component")
        XCTAssertEqual(view.captureScrollAnchor().offset, anchor.offset, accuracy: 2,
                       "the round trip landed at a different point in the same component")
    }

    /// And it stays exact however many times the trip is made — the drift was cumulative.
    func testRepeatedRoundTripsDoNotDrift() throws {
        let (view, window) = try pane(width: paneWidth(forColumns: 1, metrics: metrics))
        readerScrolls(view, toY: 1400)
        let anchor = view.captureScrollAnchor()

        for _ in 0..<3 {
            resize(window, view, to: paneWidth(forColumns: 2, metrics: metrics))
            resize(window, view, to: 900)
        }

        XCTAssertEqual(view.captureScrollAnchor().component, anchor.component,
                       "the position drifted over repeated layout changes")
    }

    /// A click in the outline is a position too: a later layout change brings the reader back to
    /// what they clicked, not to where they were before it.
    func testNavigationSetsThePositionThatIsRestored() throws {
        let (view, window) = try pane(width: paneWidth(forColumns: 1, metrics: metrics))
        let target = view.stackView.componentIndex(atY: 0) ?? 0
        readerScrolls(view, toY: 1400)

        view.scroll(toComponent: target, animated: false)
        settle()
        resize(window, view, to: paneWidth(forColumns: 2, metrics: metrics))
        resize(window, view, to: 900)

        XCTAssertEqual(view.captureScrollAnchor().component, target,
                       "a layout change undid the navigation")
    }
}
