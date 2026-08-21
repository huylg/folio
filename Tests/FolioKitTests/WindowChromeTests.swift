import AppKit
import XCTest
@testable import FolioKit

/// The window's own furniture: the outline's opening width, and the button that brings it back.
final class WindowChromeTests: XCTestCase {

    private func controller() throws -> (MainWindowController, NSWindow) {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        // A restored frame from a previous run — or another test — decides how much room the
        // divider has, which several of these assertions depend on.
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<10 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return (controller, window)
    }

    /// There has to be a button, or a collapsed sidebar can only be recovered from the menu.
    ///
    /// The system `.toggleSidebar` identifier produced no item at all here — the toolbar was
    /// empty — so the item is built explicitly.
    func testTheToolbarHasASidebarButton() throws {
        let (controller, window) = try controller()
        let toolbar = try XCTUnwrap(window.toolbar)
        let item = try XCTUnwrap(
            toolbar.items.first { $0.itemIdentifier == MainWindowController.sidebarItemIdentifier },
            "the toolbar has no sidebar button: \(toolbar.items.map(\.itemIdentifier.rawValue))"
        )
        XCTAssertNotNil(item.image, "the button has no icon")
        XCTAssertEqual(item.action, #selector(MainWindowController.toggleSidebar(_:)))
        XCTAssertIdentical(item.target as AnyObject?, controller)
    }

    /// And it is still there once the sidebar is collapsed — that is the case it exists for.
    func testTheButtonSurvivesCollapsingTheSidebar() throws {
        let (controller, window) = try controller()
        controller.toggleSidebar(nil)
        for _ in 0..<10 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        XCTAssertTrue(split.splitViewItems[0].isCollapsed, "the sidebar did not collapse")
        XCTAssertNotNil(window.toolbar?.items.first {
            $0.itemIdentifier == MainWindowController.sidebarItemIdentifier
        }, "the button vanished with the sidebar")

        // And it brings the sidebar back.
        controller.toggleSidebar(nil)
        for _ in 0..<10 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(split.splitViewItems[0].isCollapsed, "the button did not reopen the sidebar")
    }

    /// The outline opens wide: a fifth of the window landed on its 200pt minimum, where a
    /// converted book's headings are truncated past the point of being readable.
    func testTheSidebarOpensAtFullWidth() throws {
        let (_, window) = try controller()
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        let sidebar = split.splitViewItems[0]
        XCTAssertFalse(sidebar.isCollapsed, "the sidebar should start open")
        let width = sidebar.viewController.view.frame.width
        XCTAssertGreaterThan(width, sidebar.minimumThickness + 80,
                            "the outline opened at \(width)pt, near its "
                                + "\(sidebar.minimumThickness)pt minimum")
        XCTAssertLessThanOrEqual(width, sidebar.maximumThickness + 1)
    }

}

/// Navigation has to land below the toolbar, not under it.
extension WindowChromeTests {

    func testNavigationLandsBelowTheToolbar() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        let document = try MarkdownDocument(url: url)

        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        // A restored frame from a previous run — or another test — decides how much room the
        // divider has, which several of these assertions depend on.
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        controller.openDocument(url)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        let pane = try XCTUnwrap(controller.documentVC.readingPaneForTests)
        let inset = pane.scrollView.contentInsets.top
        // The window draws under its titlebar and toolbar; without that strip there is nothing to
        // test here.
        try XCTSkipIf(inset <= 0, "no toolbar inset in this configuration")
        pane.animatesNavigation = false

        for title in ["1.1", "2.2", "3.2"] {
            let index = try XCTUnwrap(document.outline.firstIndex { $0.title.hasPrefix(title) })
            pane.scroll(toAnchor: document.outline[index].anchor)
            for _ in 0..<10 {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            let built = try XCTUnwrap(pane.built)
            let range = try XCTUnwrap(built.anchors[document.outline[index].anchor])
            let component = try XCTUnwrap(built.componentIndex(containing: range.location))
            let heading = pane.stackView.frame(ofComponent: component)
            let visibleTop = pane.scrollView.contentView.bounds.minY + inset

            XCTAssertGreaterThanOrEqual(heading.minY, visibleTop - 1,
                                        "'\(title)' landed \(Int(visibleTop - heading.minY))pt "
                                            + "behind the toolbar")
            XCTAssertLessThanOrEqual(heading.minY, visibleTop + 40,
                                     "'\(title)' landed far below the top of the page")
        }
    }
}
