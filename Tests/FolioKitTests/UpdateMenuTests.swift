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

    func testLegacyConsentMigratesOnceWithoutOverridingSparklePreference() throws {
        for allowed in [true, false] {
            let suite = "folio-tests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            defaults.set(allowed, forKey: "automaticUpdateChecks")
            defaults.set(Date(), forKey: "lastUpdateCheck")
            settings.migrateUpdateSettings()
            XCTAssertEqual(settings.automaticUpdateChecks, allowed)
            XCTAssertNil(defaults.object(forKey: "automaticUpdateChecks"))
            XCTAssertNil(defaults.object(forKey: "lastUpdateCheck"))
            settings.automaticUpdateChecks = !allowed
            defaults.set(allowed, forKey: "automaticUpdateChecks")
            settings.migrateUpdateSettings()
            XCTAssertEqual(settings.automaticUpdateChecks, !allowed)
        }
    }

    func testResettingClearsSparkleConsent() throws {
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.automaticUpdateChecks = true
        UserDefaults.standard.removePersistentDomain(forName: suite)
        XCTAssertNil(settings.automaticUpdateChecks)
    }
}
