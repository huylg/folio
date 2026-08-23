import AppKit
import XCTest
@testable import FolioKit

/// The window's own furniture: the outline's opening width, and the button that brings it back.
final class WindowChromeTests: XCTestCase {

    /// A window on the reading screen. The sidebar and the toolbar button belong to a document —
    /// a window with none is on the welcome screen, which has neither.
    private func controller() throws -> (MainWindowController, NSWindow) {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        // A restored frame from a previous run — or another test — decides how much room the
        // divider has, which several of these assertions depend on.
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        controller.openDocument(sampleURL())
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
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)

        // Collapsing and expanding are animated, so the state is waited for rather than spun for a
        // fixed number of turns: `RunLoop.run(mode:before:)` returns as soon as one source fires,
        // so ten turns is however long the machine takes to fire ten sources — on a slow one that
        // is over before the animation is, and the sidebar is still shut when the assert reads it.
        controller.toggleSidebar(nil)
        XCTAssertTrue(waitUntil { split.splitViewItems[0].isCollapsed },
                      "the sidebar did not collapse")
        XCTAssertNotNil(window.toolbar?.items.first {
            $0.itemIdentifier == MainWindowController.sidebarItemIdentifier
        }, "the button vanished with the sidebar")

        // And it brings the sidebar back.
        controller.toggleSidebar(nil)
        XCTAssertTrue(waitUntil { !split.splitViewItems[0].isCollapsed },
                      "the button did not reopen the sidebar")
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

/// A document opens at its first line, not a toolbar's height down the page.
extension WindowChromeTests {

    private func sampleURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
    }

    private func openedPane(_ url: URL) throws -> (MainWindowController, NativeDocumentView) {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        controller.openDocument(url)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return (controller, try XCTUnwrap(controller.documentVC.readingPaneForTests))
    }

    /// The topmost position the clip view will accept, which is *above* the document's own
    /// origin by the strip the window draws under its chrome.
    private func topmostOffset(of pane: NativeDocumentView) -> CGFloat {
        let clip = pane.scrollView.contentView
        var probe = clip.bounds
        probe.origin.y = -100_000
        return clip.constrainBoundsRect(probe).origin.y
    }

    func testADocumentOpensAtTheTopOfThePage() throws {
        let (_, pane) = try openedPane(sampleURL())
        try XCTSkipIf(pane.scrollView.contentInsets.top <= 0,
                      "no toolbar inset in this configuration")
        XCTAssertEqual(pane.scrollView.contentView.bounds.origin.y, topmostOffset(of: pane),
                       accuracy: 1,
                       "the document opened scrolled; there is still page above the first line")
    }

    /// And the next one does too, rather than inheriting where the last was left.
    ///
    /// The second document has to be a long one. A document shorter than the viewport has no
    /// offset to inherit — the scroll clamps to the top on its own — so a short one passes this
    /// whether or not anything resets the position.
    func testOpeningAnotherDocumentReturnsToTheTop() throws {
        let (controller, pane) = try openedPane(sampleURL())
        let clip = pane.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 600))
        pane.scrollView.reflectScrolledClipView(clip)
        for _ in 0..<10 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(clip.bounds.origin.y, topmostOffset(of: pane) + 1,
                             "the scroll did not move")

        let other = try longDocument()
        defer { try? FileManager.default.removeItem(at: other) }
        controller.openDocument(other)
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(pane.stackView.frame.height, clip.bounds.height,
                             "the second document fits the window, so it would land at the top "
                                 + "whatever the pane did")
        XCTAssertEqual(clip.bounds.origin.y, topmostOffset(of: pane), accuracy: 1,
                       "the new document opened at the old one's offset")
    }

    /// A document taller than any window, written out for the test above.
    private func longDocument() throws -> URL {
        let body = (1...40).map { "## Section \($0)\n\nParagraph \($0). "
            + String(repeating: "Lorem ipsum dolor sit amet. ", count: 20) }
            .joined(separator: "\n\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-long-\(UUID().uuidString).md")
        try ("# A long second document\n\n" + body + "\n").write(to: url, atomically: true,
                                                                  encoding: .utf8)
        return url
    }
}
