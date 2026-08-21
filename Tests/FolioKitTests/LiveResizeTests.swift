import AppKit
import XCTest
@testable import FolioKit

/// The page follows the hand.
///
/// Dragging a window's edge — or the sidebar's divider — used to leave the text at its old measure
/// until the drag ended, because reflowing a book once cost hundreds of milliseconds and a drag
/// sends a size change per point. It no longer does, so the page keeps up; a budget is in place for
/// the document that is genuinely too slow to, and an animation is still coalesced into one reflow
/// at the end, which is a different thing to want.
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
        NativeDocumentView.liveReflowBudget = 0.030
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
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable],
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

    /// Dragging the window's edge: the text re-wraps while the drag is still going.
    func testTheTextFollowsAWindowDrag() throws {
        let (view, window) = try pane(width: 900)
        let before = view.stackView.columnWidth

        view.viewWillStartLiveResize()
        resize(window, view, to: 460, settling: 0)
        XCTAssertTrue(waitUntil { view.stackView.columnWidth < before },
                      "the text kept its old measure while the drag was in progress")
        view.viewDidEndLiveResize()
    }

    /// Dragging the sidebar's divider is a drag too, and AppKit sends no live-resize for it.
    func testTheTextFollowsASidebarDrag() throws {
        let (view, window) = try pane(width: 900)
        let before = view.stackView.columnWidth

        held = true
        resize(window, view, to: 460, settling: 0)
        XCTAssertTrue(waitUntil { view.stackView.columnWidth < before },
                      "the pane waited for the divider to be let go")
        held = false
    }

    /// The first change of a drag is not made to wait out the rate limit.
    func testTheFirstStepOfADragIsNotDelayed() throws {
        let (view, window) = try pane(width: 900)
        let before = view.stackView.columnWidth

        held = true
        let started = Date()
        resize(window, view, to: 460, settling: 0)
        XCTAssertTrue(waitUntil { view.stackView.columnWidth < before })
        let elapsed = Date().timeIntervalSince(started)
        held = false

        // Measuring the document is real work, so "at once" cannot mean zero — but it must not be
        // that work *plus* a wait, which is what a debounce costs on every step of a drag.
        XCTAssertLessThan(elapsed, NativeDocumentView.reflowSettleDelay,
                          "the page took \(Int(elapsed * 1000))ms to follow the hand")
    }

    /// An animation is not a hand: it gets one reflow, once it has settled.
    func testAnAnimationIsCoalescedIntoOneReflow() throws {
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

    /// A document too slow to follow stops trying, and lands once at the end.
    func testASlowDocumentFallsBackToTheEnd() throws {
        let (view, window) = try pane(width: 900)
        let before = view.stackView.columnWidth
        // Nothing reflows inside no time at all, so every document is "too slow" here.
        NativeDocumentView.liveReflowBudget = -1

        held = true
        for width in stride(from: 894.0, through: 460, by: -12) {
            resize(window, view, to: width, settling: 0.005)
        }
        XCTAssertEqual(view.stackView.columnWidth, before, accuracy: 1,
                       "a document over the budget should not be following the hand")

        held = false
        XCTAssertTrue(waitUntil { view.stackView.columnWidth < before },
                      "the reflow it kept skipping never happened")
    }

    /// Components slide to their new places rather than appearing in them.
    ///
    /// A re-measure moves everything at once — a paragraph that was at the top of the second column
    /// is now halfway down the first — and at a drag's rate that arrives as a flicker of the whole
    /// page.
    func testComponentsSlideToTheirNewPlaces() throws {
        let (view, window) = try pane(width: 900)
        let stack = view.stackView
        // Long enough to still be under way when the assertions look at it.
        DocumentStackView.glideDuration = 5
        addTeardownBlock { DocumentStackView.glideDuration = 0.14 }

        held = true
        resize(window, view, to: 460, settling: 0)
        XCTAssertTrue(waitUntil { stack.isGlidingForTests },
                      "nothing was gliding: the page jumped to its new layout")
        // And they are genuinely between two places, not sitting at the destination.
        XCTAssertGreaterThan(stack.glideDistanceForTests, 1,
                             "the components were already home, so they jumped there")
        held = false
    }

    /// And they arrive: a glide that stalls leaves the page subtly wrong for good.
    func testComponentsArriveWhereTheLayoutPutThem() throws {
        let (view, window) = try pane(width: 900)
        let stack = view.stackView

        held = true
        resize(window, view, to: 460, settling: 0)
        held = false
        XCTAssertTrue(waitUntil { !stack.isGlidingForTests && stack.columnWidth < 500 },
                      "something never finished moving")

        let component = try XCTUnwrap(stack.componentIndex(atY: 40))
        let target = try XCTUnwrap(stack.frames(ofComponent: component).first)
        XCTAssertTrue(stack.subviews.contains { abs($0.frame.minY - target.minY) < 0.5
                                                && abs($0.frame.minX - target.minX) < 0.5 },
                      "no view is where the layout put this component")
    }

    /// The size is not interpolated: the text wraps once, at the measure it is going to keep.
    func testTheWidthIsNotInterpolated() throws {
        let (view, window) = try pane(width: 900)
        let stack = view.stackView
        DocumentStackView.glideDuration = 5
        addTeardownBlock { DocumentStackView.glideDuration = 0.14 }

        held = true
        resize(window, view, to: 460, settling: 0)
        XCTAssertTrue(waitUntil { stack.isGlidingForTests })
        held = false

        // Every live component is already the width its new column gives it.
        let widths = Set(stack.subviews.filter { $0.frame.width > 1 }.map { $0.frame.width })
        XCTAssertTrue(widths.contains { abs($0 - stack.columnWidth) < 2 },
                      "no component is at the new measure: \(widths.sorted())")
    }
}
