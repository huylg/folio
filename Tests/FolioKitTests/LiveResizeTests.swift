import AppKit
import XCTest
@testable import FolioKit

/// The page waits for the hand to come off.
///
/// Reflowing means measuring every component, and a drag — the window's edge, or the sidebar's
/// divider — sends a size change per point. Doing it under the hand churns the page while the
/// reader is looking at it, and on a long document it is the main thread doing the churning for as
/// long as the drag lasts. What follows the edge is the layout already in view; the text re-wraps
/// once, when the edge is let go. An animation is coalesced the same way, into one reflow at the
/// end.
///
/// Only the width is worth re-flowing for at all: height decides how tall a spread's columns are
/// filled, and following it re-paginated the whole document for a change made to the window.
final class LiveResizeTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )
    private var held = false

    override func setUp() {
        super.setUp()
        NativeDocumentView.isDragging = { [weak self] in self?.held ?? false }
    }

    override func tearDown() {
        NativeDocumentView.isDragging = { NSEvent.pressedMouseButtons & 1 != 0 }
        NativeDocumentView.reflowSettleDelay = 0.05
        super.tearDown()
    }

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

    /// Runs the run loop for a real length of time. A fixed number of turns can be over in a
    /// millisecond — `RunLoop.run(mode:before:)` returns as soon as one source fires — which
    /// against a debounced reflow reads whatever was there before the resize.
    private func settle(_ seconds: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// The measure has to be able to change: above 548pt the text is already as wide as it is
    /// allowed to be, and a narrower window changes only the margins.
    private func resize(_ window: NSWindow, _ view: NSView, to width: CGFloat,
                        settling: TimeInterval = 0.2) {
        window.setContentSize(NSSize(width: width, height: 700))
        view.layoutSubtreeIfNeeded()
        settle(settling)
    }

    /// Only the width is the measure: dragging the bottom edge changes the window, not the text.
    private func resize(_ window: NSWindow, _ view: NSView, toHeight height: CGFloat,
                        settling: TimeInterval = 0.2) {
        window.setContentSize(NSSize(width: window.contentView?.frame.width ?? 900,
                                     height: height))
        view.layoutSubtreeIfNeeded()
        settle(settling)
    }

    /// Dragging the window's edge: the text re-wraps when the drag ends, not during it.
    ///
    /// The settle is longer than the debounce, so a drag that pauses is still a drag rather than a
    /// size change that has stopped coming.
    func testTheTextWaitsForTheWindowDragToEnd() throws {
        let (view, window) = try pane(width: 900)
        let before = view.stackView.columnWidth

        view.viewWillStartLiveResize()
        resize(window, view, to: 460, settling: 0.3)
        XCTAssertEqual(view.stackView.columnWidth, before, accuracy: 1,
                       "the document was re-measured under the hand")

        view.viewDidEndLiveResize()
        XCTAssertTrue(waitUntil { view.stackView.columnWidth < before },
                      "the reflow at the end of the drag never came")
    }

    /// Dragging the sidebar's divider is a drag too, and AppKit sends no live-resize for it — so
    /// the release is what has to be noticed, with nothing announcing it.
    func testTheTextWaitsForTheDividerToBeLetGo() throws {
        let (view, window) = try pane(width: 900)
        let before = view.stackView.columnWidth

        held = true
        resize(window, view, to: 460, settling: 0.3)
        XCTAssertEqual(view.stackView.columnWidth, before, accuracy: 1,
                       "the divider drag re-paginated the document while it was held")

        held = false
        XCTAssertTrue(waitUntil { view.stackView.columnWidth < before },
                      "letting the divider go never reflowed the page")
    }

    /// An animation is not a hand either: it gets one reflow, once it has settled.
    func testAnAnimationIsCoalescedIntoOneReflow() throws {
        // The frames have to land inside one settle window for the coalescing to be what is under
        // test. A frame costs what the machine charges, and on a slow one the default 50ms is over
        // before the second frame — the reflow that follows is the clock's doing, not the pane's.
        // A CI runner's frame measured around 55ms, so half a second leaves room to spare and
        // still lands the reflow well inside `waitUntil`.
        NativeDocumentView.reflowSettleDelay = 0.5

        let (view, window) = try pane(width: 900)
        let before = view.stackView.columnWidth

        // No pointer down, no live resize: this is what a sidebar toggle's frames look like.
        for width in stride(from: 894.0, through: 460, by: -12) {
            resize(window, view, to: width, settling: 0.005)
        }
        XCTAssertEqual(view.stackView.columnWidth, before, accuracy: 1,
                       "an animation's frames each re-paginated the document")

        XCTAssertTrue(waitUntil { view.stackView.columnWidth < before },
                      "the reflow at the end of the animation never came")
    }

    /// A vertical drag leaves the pages alone, during it and after it.
    ///
    /// Height is what a spread's columns are filled to, so following it re-paginated the whole
    /// document: every page changed height and text moved between them, for a change the reader
    /// made to the window and not to the text.
    func testAVerticalDragDoesNotRepaginate() throws {
        let (view, window) = try pane(width: 1600)
        let stack = view.stackView
        let before = (0..<stack.spreadCount).map { stack.spreadFrame(at: $0) }
        XCTAssertGreaterThan(before.count, 1,
                             "the document has to paginate for this to test anything")

        view.viewWillStartLiveResize()
        resize(window, view, toHeight: 480, settling: 0.1)
        view.viewDidEndLiveResize()
        settle()

        let after = (0..<stack.spreadCount).map { stack.spreadFrame(at: $0) }
        XCTAssertEqual(after, before, "a vertical drag re-paginated the document")
    }

    /// The width still reflows at a height that was dragged to.
    func testAWidthDragStillReflowsAtADraggedHeight() throws {
        let (view, window) = try pane(width: 900)
        let before = view.stackView.columnWidth

        resize(window, view, toHeight: 480)
        held = true
        window.setContentSize(NSSize(width: 460, height: 480))
        view.layoutSubtreeIfNeeded()
        settle(0.1)
        held = false

        XCTAssertTrue(waitUntil { view.stackView.columnWidth < before },
                      "the measure stopped following the window sideways")
    }

    /// The one thing height does have to move: the empty runway that lets the last heading be
    /// scrolled to the top. Without it a window made taller stops being able to park them.
    func testTheRunwayAfterTheDocumentFollowsTheHeight() throws {
        let (view, window) = try pane(width: 900)
        let short = view.stackView.trailingParkingSpace

        resize(window, view, toHeight: 1000)
        XCTAssertGreaterThan(view.stackView.trailingParkingSpace, short,
                             "a taller window did not get more room to park its last heading")
    }
}
