import AppKit
import XCTest
@testable import FolioKit

/// Following a link to another Markdown file opens it in a new tab, so the document it was
/// clicked in — and the reading position within it — stays where the reader left it.
final class LinkOpeningTests: XCTestCase {

    private func vaultURL(_ components: String...) -> URL {
        var url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault")
        components.forEach { url.appendPathComponent($0) }
        return url
    }

    private func openedController(_ url: URL) throws -> MainWindowController {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        controller.openDocument(url)
        window.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    /// A link to a different file is routed to the new-tab hook, and the source window keeps
    /// its own document.
    func testALinkToAnotherFileAsksForANewTab() throws {
        let source = vaultURL("Drafts", "Sparse attention under bounded compute.md")
        let target = vaultURL("Method", "Kernel notes.md")
        let controller = try openedController(source)

        var opened: [(URL, String?)] = []
        controller.onOpenLinkInNewTab = { url, anchor in opened.append((url, anchor)) }

        controller.openRelativeLink(target, scrollTo: "dispatch")

        XCTAssertEqual(opened.count, 1, "the link did not ask for a new tab")
        XCTAssertEqual(opened.first?.0.standardizedFileURL.path, target.standardizedFileURL.path)
        XCTAssertEqual(opened.first?.1, "dispatch", "the link's fragment was dropped")
        XCTAssertEqual(controller.currentDocument?.url.standardizedFileURL.path,
                       source.standardizedFileURL.path,
                       "the source window swapped its document instead of keeping it")
    }

    /// A link back into the document already on screen is a jump within it — not a second tab
    /// showing the same file.
    func testALinkIntoTheSameDocumentDoesNotOpenATab() throws {
        let source = vaultURL("Drafts", "Sparse attention under bounded compute.md")
        let controller = try openedController(source)

        var openedTabs = 0
        controller.onOpenLinkInNewTab = { _, _ in openedTabs += 1 }

        controller.openRelativeLink(source, scrollTo: nil)

        XCTAssertEqual(openedTabs, 0, "a self-link opened a duplicate tab")
        XCTAssertEqual(controller.currentDocument?.url.standardizedFileURL.path,
                       source.standardizedFileURL.path)
    }

    /// Without the hook — a controller not owned by the app delegate — the link still opens,
    /// in place, rather than going nowhere.
    func testWithoutTheHookTheLinkOpensInPlace() throws {
        let source = vaultURL("Drafts", "Sparse attention under bounded compute.md")
        let target = vaultURL("Method", "Kernel notes.md")
        let controller = try openedController(source)
        controller.onOpenLinkInNewTab = nil

        controller.openRelativeLink(target, scrollTo: nil)

        XCTAssertEqual(controller.currentDocument?.url.standardizedFileURL.path,
                       target.standardizedFileURL.path,
                       "the link opened neither a tab nor the document itself")

        // In-place navigation is a push like any other: the source document is now history,
        // the back button appears, and back returns to it.
        XCTAssertTrue(controller.canGoBack)
        XCTAssertNotNil(controller.window?.toolbar?.items.first {
            $0.itemIdentifier == MainWindowController.backItemIdentifier
        }, "navigating in place did not surface a back button")
        controller.goBack(nil)
        XCTAssertEqual(controller.currentDocument?.url.standardizedFileURL.path,
                       source.standardizedFileURL.path,
                       "back did not return to the document the link was followed from")
    }

    /// The back button behaves like a navigation bar's: it walks the history one screen at a
    /// time — document to document to welcome — and is gone at the root of the stack.
    func testBackWalksTheHistoryLikeANavigator() throws {
        let first = vaultURL("Drafts", "Sparse attention under bounded compute.md")
        let second = vaultURL("Method", "Kernel notes.md")
        // `openedController` shows the window first, so the welcome screen was really visited.
        let controller = try openedController(first)
        XCTAssertTrue(controller.canGoBack, "opening from the welcome screen left no history")

        controller.openDocument(second)
        XCTAssertEqual(controller.currentDocument?.url.standardizedFileURL.path,
                       second.standardizedFileURL.path)

        controller.goBack(nil)
        XCTAssertEqual(controller.currentDocument?.url.standardizedFileURL.path,
                       first.standardizedFileURL.path, "back skipped over the first document")
        XCTAssertTrue(controller.canGoBack, "the welcome screen fell out of the history")

        controller.goBack(nil)
        XCTAssertNil(controller.currentDocument, "back did not reach the welcome screen")
        XCTAssertFalse(controller.showsDocumentScreen)
        XCTAssertFalse(controller.canGoBack, "there is history below the root of the stack")

        // At the root, back is a no-op — not a crash, not a blank screen.
        controller.goBack(nil)
        XCTAssertNil(controller.currentDocument)
    }

    /// The delegate answers the hook by attaching the new window to the source window's tab
    /// group, with the linked document open in it.
    func testTheDelegateOpensTheLinkAsATabOfTheSourceWindow() throws {
        let source = vaultURL("Drafts", "Sparse attention under bounded compute.md")
        let target = vaultURL("Method", "Kernel notes.md")

        let delegate = AppDelegate()
        let sourceController = delegate.makeWindowController()
        let window = try XCTUnwrap(sourceController.window)
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        sourceController.openDocument(source)

        // Every Folio window shares one tabbing identifier, so windows left behind by other
        // tests may already sit in this group; the assertion is on what the link adds.
        let before = Set((window.tabbedWindows ?? [window]).map { ObjectIdentifier($0) })

        sourceController.onOpenLinkInNewTab?(target, nil)

        let tabs = try XCTUnwrap(window.tabbedWindows, "no tab was attached to the window")
        let added = tabs.filter { !before.contains(ObjectIdentifier($0)) }
        XCTAssertEqual(added.count, 1, "the link attached \(added.count) tabs")
        let openedController = try XCTUnwrap(added.first?.windowController as? MainWindowController)
        XCTAssertEqual(openedController.currentDocument?.url.standardizedFileURL.path,
                       target.standardizedFileURL.path,
                       "the new tab is not showing the linked document")
        XCTAssertEqual(sourceController.currentDocument?.url.standardizedFileURL.path,
                       source.standardizedFileURL.path,
                       "the source tab lost its document")

        // The new tab landed straight on its document — its history is empty, so it is at the
        // root of its stack: no back button, and the Back command is disabled and does nothing.
        let openedWindow = try XCTUnwrap(added.first)
        XCTAssertNil(openedWindow.toolbar?.items.first {
            $0.itemIdentifier == MainWindowController.backItemIdentifier
        }, "a link-opened tab has a back button, but it has no history")
        let backItem = NSMenuItem(title: "Back",
                                  action: #selector(MainWindowController.goBack(_:)),
                                  keyEquivalent: "")
        XCTAssertFalse(openedController.validateMenuItem(backItem),
                       "Back is enabled in a tab with no history")
        openedController.goBack(nil)
        XCTAssertNotNil(openedController.currentDocument,
                        "going back emptied a tab with no screen to go back to")

        // While the source window — which did come from the welcome screen — keeps its button.
        XCTAssertNotNil(window.toolbar?.items.first {
            $0.itemIdentifier == MainWindowController.backItemIdentifier
        }, "the source window lost its back button")

        added.forEach { $0.close() }
        window.close()
    }
}
