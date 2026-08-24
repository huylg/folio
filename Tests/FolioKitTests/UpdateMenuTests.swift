import AppKit
import XCTest
@testable import FolioKit

/// `Check for Updates…` and the setting behind it.
///
/// The menu item is the path that always works — an automatic check is a preference, and a reader
/// who declined it still has to be able to ask. So it is pinned here rather than left to depend on
/// whatever `automaticUpdateChecks` happens to hold.
final class UpdateMenuTests: XCTestCase {

    private func appMenu() throws -> NSMenu {
        // The builder hangs the Services menu off `NSApp`, which does not exist until something
        // asks for it.
        _ = NSApplication.shared
        let main = MainMenuBuilder.build()
        return try XCTUnwrap(main.items.first { $0.title == "Folio" }?.submenu, "no Folio menu")
    }

    func testTheItemIsInTheAppMenuUnderAbout() throws {
        let menu = try appMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Check for Updates…" },
                                 "no Check for Updates item")
        XCTAssertEqual(item.action, #selector(AppDelegate.checkForUpdates(_:)))

        let about = try XCTUnwrap(menu.items.firstIndex { $0.title == "About Folio" })
        let updates = try XCTUnwrap(menu.items.firstIndex { $0.title == "Check for Updates…" })
        XCTAssertEqual(updates, about + 1, "it belongs directly under About, where macOS puts it")
    }

    /// No shortcut: it is not something a reader should be able to fire by accident, and every
    /// letter worth having is already spoken for.
    func testTheItemHasNoKeyEquivalent() throws {
        let item = try XCTUnwrap(try appMenu().items.first { $0.title == "Check for Updates…" })
        XCTAssertEqual(item.keyEquivalent, "")
    }

    func testTheAppDelegateAnswersForIt() {
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.checkForUpdates(_:))))
    }

    // MARK: The setting

    private func scratchSettings() throws -> AppSettings {
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }

    /// Three states, not two. A fresh install has not been asked yet, and that is what stops the
    /// app checking before anyone has said it may — the same stance `loadRemoteImages` takes two
    /// panes away in Settings.
    func testAutomaticChecksAreUnansweredUntilSomebodyAnswers() throws {
        let settings = try scratchSettings()
        XCTAssertNil(settings.automaticUpdateChecks, "a fresh install has not been asked")

        settings.automaticUpdateChecks = false
        XCTAssertEqual(settings.automaticUpdateChecks, false, "declining is an answer, not a gap")

        settings.automaticUpdateChecks = true
        XCTAssertEqual(settings.automaticUpdateChecks, true)

        settings.automaticUpdateChecks = nil
        XCTAssertNil(settings.automaticUpdateChecks, "back to unasked")
    }

    func testTheSkippedVersionAndLastCheckRoundTrip() throws {
        let settings = try scratchSettings()
        XCTAssertNil(settings.skippedVersion)
        XCTAssertNil(settings.lastUpdateCheck)

        settings.skippedVersion = "1.4.0"
        XCTAssertEqual(settings.skippedVersion, "1.4.0")
        settings.skippedVersion = nil
        XCTAssertNil(settings.skippedVersion)

        let when = Date(timeIntervalSince1970: 1_780_000_000)
        settings.lastUpdateCheck = when
        XCTAssertEqual(settings.lastUpdateCheck?.timeIntervalSince1970 ?? 0,
                       when.timeIntervalSince1970, accuracy: 1)
    }

    /// The updater's settings live in the same domain as everything else, so Reset All Settings
    /// clears them too — including the answer to the first-run question, which is then asked
    /// again rather than silently kept.
    func testResettingClearsTheUpdateSettingsToo() throws {
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.automaticUpdateChecks = true
        settings.skippedVersion = "1.4.0"
        UserDefaults.standard.removePersistentDomain(forName: suite)

        XCTAssertNil(settings.automaticUpdateChecks)
        XCTAssertNil(settings.skippedVersion)
    }
}
