import AppKit
import XCTest
@testable import FolioKit

/// A divider drag is two gestures: resizing the outline, and closing it.
///
/// Both are driven here with the pointer hooks rather than with synthesized events, because a
/// synthesized drag does not survive `NSSplitView`'s own event tracking — the tracking loop reads
/// one event and stops.
final class SidebarDragTests: XCTestCase {

    private var pointer = NSPoint(x: 0, y: 0)
    private var held = false

    override func setUp() {
        super.setUp()
        MainWindowController.isPointerDown = { [weak self] in self?.held ?? false }
        MainWindowController.pointerX = { [weak self] _ in self?.pointer.x ?? 0 }
    }

    override func tearDown() {
        MainWindowController.isPointerDown = { NSEvent.pressedMouseButtons & 1 != 0 }
        MainWindowController.pointerX = { splitView in
            guard let window = splitView.window else { return .greatestFiniteMagnitude }
            return splitView.convert(window.mouseLocationOutsideOfEventStream, from: nil).x
        }
        super.tearDown()
    }

    private func openWindow() throws -> (MainWindowController, NSSplitViewController) {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        // A frame restored from a previous run decides how much room the divider has.
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        return (controller, try XCTUnwrap(window.contentViewController as? NSSplitViewController))
    }

    private func settle() {
        for _ in 0..<30 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Grabs the divider where it currently is.
    private func grabDivider(_ split: NSSplitViewController) {
        pointer.x = split.splitView.arrangedSubviews[0].frame.width
        held = true
    }

    /// Moves the pointer and lets the split view lay out, as a drag does — in short steps,
    /// because a hand does not teleport and the divider is only grabbed within a few points.
    private func dragTo(_ x: CGFloat, _ split: NSSplitViewController) {
        let start = split.splitView.arrangedSubviews[0].frame.width
        for step in stride(from: start, through: x, by: start > x ? -8 : 8) {
            pointer.x = step
            split.splitView.setPosition(step, ofDividerAt: 0)
            split.splitView.layoutSubtreeIfNeeded()
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        pointer.x = x
        split.splitView.setPosition(x, ofDividerAt: 0)
        split.splitView.layoutSubtreeIfNeeded()
        settle()
    }

    /// Dragging inward stops at the outline's minimum: that far, the gesture is a resize.
    func testDraggingToTheMinimumResizesAndKeepsTheSidebar() throws {
        let (_, split) = try openWindow()
        let sidebar = split.splitViewItems[0]

        grabDivider(split)
        dragTo(sidebar.minimumThickness + 30, split)
        held = false
        settle()

        XCTAssertFalse(sidebar.isCollapsed, "a resize closed the sidebar")
        XCTAssertEqual(split.splitView.arrangedSubviews[0].frame.width,
                       sidebar.minimumThickness + 30, accuracy: 2)
    }

    /// Carried on past the minimum, the same drag closes it — with the animation, which means
    /// going through the same code the toolbar button uses.
    ///
    /// It closes when the hand comes up, not the instant the pointer passes the mark: until then
    /// the split view is still tracking the divider, and an animation run against that tracking
    /// fights it.
    func testDraggingPastTheMinimumClosesTheSidebar() throws {
        let (_, split) = try openWindow()
        let sidebar = split.splitViewItems[0]

        grabDivider(split)
        dragTo(sidebar.minimumThickness, split)
        XCTAssertFalse(sidebar.isCollapsed, "the sidebar vanished while the drag was still a drag")
        XCTAssertFalse(sidebar.canCollapse,
                       "AppKit's own snap was left on, so it will close the sidebar unanimated")

        // The divider is clamped now; the pointer carries on toward the edge, then lets go.
        pointer.x = 20
        settle()
        XCTAssertFalse(sidebar.isCollapsed, "the sidebar closed mid-drag")
        held = false

        XCTAssertTrue(waitUntil(2) { sidebar.isCollapsed },
                      "carrying the drag past the minimum did not close the sidebar")
        // And it is collapsible again, or the toolbar button would stop working.
        XCTAssertTrue(sidebar.canCollapse)
    }

    /// A window resize is not a drag on the divider, even though it resizes the same views.
    func testResizingTheWindowDoesNotCloseTheSidebar() throws {
        let (controller, split) = try openWindow()
        let window = try XCTUnwrap(controller.window)
        let sidebar = split.splitViewItems[0]

        // The pointer is on the window's left edge, which is where the closing test puts it.
        held = true
        pointer.x = 0
        window.setContentSize(NSSize(width: 900, height: 700))
        split.splitView.layoutSubtreeIfNeeded()
        settle()

        XCTAssertFalse(sidebar.isCollapsed, "resizing the window closed the sidebar")
        held = false
    }
}
