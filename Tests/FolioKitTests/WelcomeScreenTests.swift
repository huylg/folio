import AppKit
import XCTest
@testable import FolioKit

/// The welcome screen is a screen, and the window navigates between it and the reading screen.
///
/// It used to be a view hidden behind the reading pane: the window kept an outline sidebar with
/// nothing to list and a toolbar button for a sidebar that had nothing in it, and opening a
/// document swapped one hidden view for another. These assert the two screens are two screens,
/// while their unified titlebar chrome stays consistent.
final class WelcomeScreenTests: XCTestCase {

    private var savedRecents: [AppSettings.Recent] = []

    override func setUp() {
        super.setUp()
        savedRecents = AppSettings.shared.recents
    }

    override func tearDown() {
        AppSettings.shared.recents = savedRecents
        super.tearDown()
    }

    private func sampleURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
    }

    private func newWindow() throws -> (MainWindowController, NSWindow) {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        return (controller, window)
    }

    private func settle() {
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// A fresh window is the welcome screen, whole: no split view, no sidebar, and no document
    /// controls. Its empty toolbar preserves the same unified titlebar as the reading screen.
    func testAFreshWindowIsTheWelcomeScreen() throws {
        let (controller, window) = try newWindow()
        XCTAssertFalse(controller.showsDocumentScreen)
        XCTAssertIdentical(window.contentViewController, controller.welcomeVC,
                           "the window is not showing the welcome screen")
        XCTAssertNil(window.contentViewController as? NSSplitViewController,
                     "the reading screen's split view is still the window's content")
        let toolbar = try XCTUnwrap(window.toolbar,
                                    "the welcome screen has different titlebar chrome")
        XCTAssertTrue(toolbar.items.isEmpty,
                      "the welcome screen carries document controls: "
                          + "\(toolbar.items.map(\.itemIdentifier.rawValue))")
        XCTAssertEqual(window.title, "Folio")
    }

    /// Navigating changes the toolbar's controls, not the height of the titlebar around them.
    func testBothScreensUseConsistentTitlebarChrome() throws {
        let (controller, window) = try newWindow()
        let welcomeChromeHeight = window.frame.height - window.contentLayoutRect.height

        controller.openDocument(sampleURL())
        settle()
        let documentChromeHeight = window.frame.height - window.contentLayoutRect.height

        XCTAssertEqual(documentChromeHeight, welcomeChromeHeight, accuracy: 1,
                       "the titlebar changes height when a document opens")
    }

    /// The sidebar command is disabled there rather than toggling a sidebar that is not on screen.
    func testTheSidebarCommandIsDisabledOnTheWelcomeScreen() throws {
        let (controller, _) = try newWindow()
        let item = NSMenuItem(title: "Hide Sidebar",
                              action: #selector(MainWindowController.toggleSidebar(_:)),
                              keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item))
    }

    /// Opening a document navigates: the split view arrives, and the chrome with it.
    func testOpeningADocumentNavigatesToTheReadingScreen() throws {
        let (controller, window) = try newWindow()
        controller.openDocument(sampleURL())
        settle()

        XCTAssertTrue(controller.showsDocumentScreen)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController,
                                 "the window did not navigate to the reading screen")
        XCTAssertFalse(split.splitViewItems[0].isCollapsed, "the outline arrived collapsed")
        XCTAssertNotNil(window.toolbar?.items.first {
            $0.itemIdentifier == MainWindowController.sidebarItemIdentifier
        }, "the reading screen has no sidebar button")
        XCTAssertEqual(window.title, sampleURL().lastPathComponent)

        // And the document itself is on screen, laid out at the pane's real width.
        let pane = try XCTUnwrap(controller.documentVC.readingPaneForTests)
        XCTAssertNotNil(pane.built, "nothing was rendered")
        XCTAssertGreaterThan(pane.frame.width, 400,
                             "the pane rendered before it had a width: \(pane.frame.width)pt")
    }

    /// Clicking a file in the recents list is the navigation, not a state flip somewhere behind
    /// the pane: the window comes out on the reading screen, showing that file.
    func testClickingARecentNavigatesToTheReadingScreen() throws {
        AppSettings.shared.recents = [
            AppSettings.Recent(path: sampleURL().path, date: Date())
        ]
        let (controller, window) = try newWindow()
        controller.welcomeVC.reloadRecents()

        let row = try XCTUnwrap(controller.welcomeVC.recentRows.first,
                                "the welcome screen listed no recents")
        row.onClick?()
        settle()

        XCTAssertTrue(controller.showsDocumentScreen,
                      "clicking a recent left the window on the welcome screen")
        XCTAssertNotNil(window.contentViewController as? NSSplitViewController)
        XCTAssertEqual(controller.currentDocument?.url.standardizedFileURL,
                       sampleURL().standardizedFileURL)
    }

    /// Clearing the recents empties the list on a welcome screen that is already open.
    func testClearingTheRecentsEmptiesTheList() throws {
        AppSettings.shared.recents = [
            AppSettings.Recent(path: sampleURL().path, date: Date())
        ]
        let (controller, _) = try newWindow()
        controller.welcomeVC.reloadRecents()
        XCTAssertEqual(controller.welcomeVC.recentRows.count, 1)

        AppSettings.shared.recents = []
        controller.reloadRecents()
        XCTAssertTrue(controller.welcomeVC.recentRows.isEmpty,
                      "the screen is still listing files that were cleared")
    }

    /// The reading screen has a way back out of it.
    func testTheReadingScreenHasABackButton() throws {
        let (controller, window) = try newWindow()
        controller.openDocument(sampleURL())
        settle()

        let item = try XCTUnwrap(
            window.toolbar?.items.first {
                $0.itemIdentifier == MainWindowController.backItemIdentifier
            },
            "the reading screen has no back button: "
                + "\(window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])"
        )
        XCTAssertNotNil(item.image, "the button has no icon")
        XCTAssertEqual(item.action, #selector(MainWindowController.goBack(_:)))
        XCTAssertIdentical(item.target as AnyObject?, controller)

        // Over the document, not over the outline: it is the reading screen being left.
        let identifiers = window.toolbar?.items.map(\.itemIdentifier) ?? []
        let separator = try XCTUnwrap(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        let back = try XCTUnwrap(
            identifiers.firstIndex(of: MainWindowController.backItemIdentifier))
        XCTAssertGreaterThan(back, separator, "the back button sits over the sidebar")
    }

    /// Going back leaves the window as a fresh one: welcome screen, no document controls.
    func testBackReturnsToTheWelcomeScreen() throws {
        let (controller, window) = try newWindow()
        controller.openDocument(sampleURL())
        settle()

        controller.goBack(nil)
        settle()

        XCTAssertFalse(controller.showsDocumentScreen)
        XCTAssertIdentical(window.contentViewController, controller.welcomeVC,
                           "the window did not go back to the welcome screen")
        XCTAssertNil(controller.currentDocument)
        let toolbar = try XCTUnwrap(window.toolbar,
                                    "the welcome screen lost its unified titlebar")
        XCTAssertTrue(toolbar.items.isEmpty,
                      "the reading screen's controls came back with it")
        XCTAssertEqual(window.title, "Folio")
        // The document just read is a recent now, so the list it comes back to is up to date.
        XCTAssertFalse(controller.welcomeVC.recentRows.isEmpty,
                       "the welcome screen came back with an empty recents list")
    }

    /// And the trip can be made again: back, then into a document, chrome and all.
    func testTheWindowCanNavigateBackAndForwardAgain() throws {
        let (controller, window) = try newWindow()
        controller.openDocument(sampleURL())
        settle()
        controller.goBack(nil)
        settle()

        let row = try XCTUnwrap(controller.welcomeVC.recentRows.first,
                                "the welcome screen listed no recents to go back into")
        row.onClick?()
        settle()

        XCTAssertTrue(controller.showsDocumentScreen)
        XCTAssertNotNil(window.contentViewController as? NSSplitViewController)
        XCTAssertNotNil(window.toolbar?.items.first {
            $0.itemIdentifier == MainWindowController.backItemIdentifier
        }, "the second visit has no back button")
        let pane = try XCTUnwrap(controller.documentVC.readingPaneForTests)
        XCTAssertNotNil(pane.built, "nothing was rendered on the way back in")
    }

    /// The back command is a reading-screen command, disabled where there is nothing to leave.
    func testTheBackCommandIsDisabledOnTheWelcomeScreen() throws {
        let (controller, _) = try newWindow()
        let item = NSMenuItem(title: "Back to Welcome",
                              action: #selector(MainWindowController.goBack(_:)),
                              keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item),
                       "back is offered with nothing to go back from")

        controller.openDocument(sampleURL())
        settle()
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    /// A width the reader dragged for themselves survives the round trip.
    func testGoingBackAndForwardKeepsTheOutlineWidth() throws {
        let (controller, window) = try newWindow()
        controller.openDocument(sampleURL())
        settle()
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        split.splitView.setPosition(240, ofDividerAt: 0)
        split.splitView.layoutSubtreeIfNeeded()
        let width = split.splitViewItems[0].viewController.view.frame.width

        controller.goBack(nil)
        settle()
        controller.openDocument(sampleURL())
        settle()

        XCTAssertEqual(split.splitViewItems[0].viewController.view.frame.width, width,
                       accuracy: 1,
                       "the outline was reset to its opening width on the way back in")
    }

    /// Swapping the window's content view controller resizes the window to the incoming view.
    /// The reader's window is theirs: navigating must not move it.
    func testNavigatingDoesNotResizeTheWindow() throws {
        let (controller, window) = try newWindow()
        let before = window.frame
        controller.openDocument(sampleURL())
        settle()
        XCTAssertEqual(window.frame.width, before.width, accuracy: 1,
                       "the window resized on navigating")
        XCTAssertEqual(window.frame.height, before.height, accuracy: 1,
                       "the window resized on navigating")
        XCTAssertEqual(window.frame.origin.y, before.origin.y, accuracy: 1,
                       "the window moved on navigating")
    }
}
