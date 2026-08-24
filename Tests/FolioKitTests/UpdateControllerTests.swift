import XCTest
@testable import FolioKit

/// What the updater decides, given what GitHub said.
///
/// The decisions worth pinning are the ones about *not* acting: a background check that finds
/// nothing says nothing, a background check that cannot reach GitHub says nothing, and a version
/// the reader skipped stays skipped. Each of those is a state the badge would otherwise put in the
/// titlebar over a document, unasked.
final class UpdateControllerTests: XCTestCase {

    // MARK: Fixtures

    private final class StubFeed: ReleaseFeed {
        var result: Result<Release, UpdateError>
        var calls = 0

        init(_ result: Result<Release, UpdateError>) { self.result = result }

        func latest(completion: @escaping (Result<Release, UpdateError>) -> Void) {
            calls += 1
            completion(result)
        }
    }

    private func release(_ version: String) -> Release {
        Release(version: AppVersion(version)!,
                tag: "v\(version)",
                notes: "Notes for \(version)",
                publishedAt: nil,
                assetURL: URL(string: "https://github.com/huylg/folio/x/Folio-v\(version).zip")!,
                assetName: "Folio-v\(version).zip",
                byteCount: 1024,
                checksumURL: nil,
                pageURL: URL(string: "https://github.com/huylg/folio/releases/tag/v\(version)")!)
    }

    /// A scratch defaults suite, so a test's skipped version and check timestamp never leak into
    /// the domain the app and every other test share.
    private func scratchSettings() throws -> AppSettings {
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }

    private func controller(feed: StubFeed,
                            settings: AppSettings,
                            running: String? = "1.3.0",
                            installed: Bool = true) -> UpdateController {
        UpdateController(feed: feed,
                         settings: settings,
                         runningVersion: running.flatMap(AppVersion.init),
                         installedBundle: {
                             installed ? URL(fileURLWithPath: "/Applications/Folio.app") : nil
                         })
    }

    /// `check` hops to the main queue to settle, so let the run loop turn before asserting.
    private func settle() {
        let deadline = Date().addingTimeInterval(1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        _ = deadline
    }

    // MARK: The check

    func testANewerReleaseIsOffered() throws {
        let feed = StubFeed(.success(release("1.4.0")))
        let update = controller(feed: feed, settings: try scratchSettings())

        update.check(manual: true)
        settle()

        XCTAssertEqual(update.state, .available(release("1.4.0")))
        XCTAssertEqual(update.pendingRelease?.version, AppVersion("1.4.0"))
    }

    func testTheSameOrAnOlderReleaseIsNotOffered() throws {
        for version in ["1.3.0", "1.2.9", "0.9.0"] {
            let feed = StubFeed(.success(release(version)))
            let update = controller(feed: feed, settings: try scratchSettings())

            update.check(manual: true)
            settle()

            XCTAssertEqual(update.state, .upToDate(AppVersion("1.3.0")!),
                           "\(version) should not be offered over 1.3.0")
        }
    }

    /// A manual check answers; a background one that finds nothing stays quiet. The reader who
    /// clicked the menu item asked a question and is owed an answer, and nobody else did.
    func testAnAutomaticCheckThatFindsNothingSaysNothing() throws {
        let settings = try scratchSettings()
        settings.automaticUpdateChecks = true
        let feed = StubFeed(.success(release("1.3.0")))
        let update = controller(feed: feed, settings: settings)

        update.check(manual: false)
        settle()

        XCTAssertEqual(update.state, .idle)
        XCTAssertEqual(feed.calls, 1, "the check should still have run")
    }

    /// Same reasoning for a failure: a badge reading "Update Failed" over a flaky connection is
    /// noise about something the reader was not doing.
    func testAnAutomaticCheckThatFailsSaysNothingAndAManualOneReports() throws {
        let settings = try scratchSettings()
        settings.automaticUpdateChecks = true
        let feed = StubFeed(.failure(.network("offline")))

        let background = controller(feed: feed, settings: settings)
        background.check(manual: false)
        settle()
        XCTAssertEqual(background.state, .idle)

        let manual = controller(feed: feed, settings: try scratchSettings())
        manual.check(manual: true)
        settle()
        XCTAssertEqual(manual.state, .failed(.network("offline")))
    }

    // MARK: Skipping

    func testASkippedVersionStaysSkippedUntilTheReaderAsks() throws {
        let settings = try scratchSettings()
        settings.automaticUpdateChecks = true
        let feed = StubFeed(.success(release("1.4.0")))

        let update = controller(feed: feed, settings: settings)
        update.check(manual: true)
        settle()
        guard case .available(let offered) = update.state else {
            return XCTFail("1.4.0 should have been offered")
        }
        update.skip(offered)
        XCTAssertEqual(update.state, .idle)
        XCTAssertEqual(settings.skippedVersion, "1.4.0")

        // Background: silent.
        let background = controller(feed: feed, settings: settings)
        background.check(manual: false)
        settle()
        XCTAssertEqual(background.state, .idle)

        // Asked directly: offered again, because the reader is asking now.
        let asked = controller(feed: feed, settings: settings)
        asked.check(manual: true)
        settle()
        XCTAssertEqual(asked.state, .available(release("1.4.0")))
    }

    func testANewerReleaseThanTheSkippedOneIsStillOffered() throws {
        let settings = try scratchSettings()
        settings.automaticUpdateChecks = true
        settings.skippedVersion = "1.4.0"
        let feed = StubFeed(.success(release("1.5.0")))

        let update = controller(feed: feed, settings: settings)
        update.check(manual: false)
        settle()

        XCTAssertEqual(update.state, .available(release("1.5.0")))
    }

    // MARK: The throttle

    func testTheDailyThrottleHoldsBackAnAutomaticCheckButNeverAManualOne() throws {
        let settings = try scratchSettings()
        settings.automaticUpdateChecks = true
        settings.lastUpdateCheck = Date().addingTimeInterval(-60 * 60)
        let feed = StubFeed(.success(release("1.4.0")))

        let background = controller(feed: feed, settings: settings)
        XCTAssertFalse(background.isAutomaticCheckDue)
        background.check(manual: false)
        settle()
        XCTAssertEqual(feed.calls, 0, "an hour after the last check, nothing should be requested")
        XCTAssertEqual(background.state, .idle)

        let manual = controller(feed: feed, settings: settings)
        manual.check(manual: true)
        settle()
        XCTAssertEqual(feed.calls, 1)
        XCTAssertEqual(manual.state, .available(release("1.4.0")))
    }

    func testTheThrottleExpiresAfterADay() throws {
        let settings = try scratchSettings()
        settings.automaticUpdateChecks = true
        settings.lastUpdateCheck = Date().addingTimeInterval(-UpdateController.automaticInterval - 1)
        let update = controller(feed: StubFeed(.success(release("1.4.0"))), settings: settings)

        XCTAssertTrue(update.isAutomaticCheckDue)
    }

    /// Off means off: no request at all, not a request whose answer is discarded.
    func testAnAutomaticCheckDoesNothingWhenTheSettingIsOffOrUnanswered() throws {
        for choice: Bool? in [false, nil] {
            let settings = try scratchSettings()
            settings.automaticUpdateChecks = choice
            let feed = StubFeed(.success(release("1.4.0")))
            let update = controller(feed: feed, settings: settings)

            update.check(manual: false)
            settle()

            XCTAssertEqual(feed.calls, 0, "setting \(String(describing: choice)) should not check")
            XCTAssertEqual(update.state, .idle)
        }
    }

    // MARK: Refusals

    func testABuildThatCannotNameItsVersionRefusesToCompare() throws {
        let feed = StubFeed(.success(release("1.4.0")))
        let update = controller(feed: feed, settings: try scratchSettings(), running: nil)

        update.check(manual: true)
        settle()

        XCTAssertEqual(update.state, .failed(.unknownRunningVersion))
        XCTAssertEqual(feed.calls, 0, "there is nothing to compare against, so do not ask")
    }

    /// `swift run` and the test runner have no bundle to replace, and the updater says so rather
    /// than downloading something it could not install.
    func testABuildThatIsNotAnInstalledAppRefusesToUpdate() throws {
        let feed = StubFeed(.success(release("1.4.0")))
        let update = controller(feed: feed, settings: try scratchSettings(), installed: false)

        update.check(manual: true)
        settle()

        XCTAssertEqual(update.state, .failed(.notAnInstalledApp))
        XCTAssertEqual(feed.calls, 0)
    }

    func testASecondCheckIsIgnoredWhileOneIsRunning() throws {
        /// A feed that never answers, so the controller is left in `.checking`.
        final class SilentFeed: ReleaseFeed {
            var calls = 0
            func latest(completion: @escaping (Result<Release, UpdateError>) -> Void) { calls += 1 }
        }
        let feed = SilentFeed()
        let update = UpdateController(feed: feed,
                                      settings: try scratchSettings(),
                                      runningVersion: AppVersion("1.3.0"),
                                      installedBundle: { URL(fileURLWithPath: "/Applications/Folio.app") })

        update.check(manual: true)
        XCTAssertEqual(update.state, .checking)
        XCTAssertTrue(update.isBusy)
        update.check(manual: true)

        XCTAssertEqual(feed.calls, 1, "double-clicking the menu item should not double-request")
    }

    // MARK: Surviving a quit

    /// Regression cover for an update that was found and then forgotten.
    ///
    /// The pill appeared, the reader quit without acting on it, and on the next launch the
    /// once-a-day throttle stopped the check running — so the app showed nothing, and went on
    /// showing nothing until the throttle expired. It knew and had thrown the answer away. The
    /// release is remembered now and put back without a network call.
    func testAnUpdateFoundBeforeAQuitIsStillThereAfterOne() throws {
        let settings = try scratchSettings()
        settings.automaticUpdateChecks = true
        let feed = StubFeed(.success(release("1.4.0")))

        let before = controller(feed: feed, settings: settings)
        before.check(manual: false)
        settle()
        XCTAssertEqual(before.state, .available(release("1.4.0")))
        XCTAssertEqual(settings.pendingUpdate, release("1.4.0"), "it should have been remembered")

        // A new launch, inside the throttle window: no check will run at all.
        let after = controller(feed: feed, settings: settings)
        XCTAssertFalse(after.isAutomaticCheckDue)
        after.restorePendingUpdate()
        after.check(manual: false)
        settle()

        XCTAssertEqual(after.state, .available(release("1.4.0")),
                       "the update was found yesterday and is still waiting")
        XCTAssertEqual(feed.calls, 1, "restoring should cost no network")
    }

    func testARememberedUpdateIsDroppedOnceItIsNoLongerNewer() throws {
        let settings = try scratchSettings()
        settings.pendingUpdate = release("1.3.0")

        // The reader installed 1.3.0 by hand in the meantime.
        let update = controller(feed: StubFeed(.success(release("1.3.0"))),
                                settings: settings, running: "1.3.0")
        update.restorePendingUpdate()

        XCTAssertEqual(update.state, .idle)
        XCTAssertNil(settings.pendingUpdate, "a stale remembered update should be forgotten")
    }

    func testARememberedUpdateThatWasSkippedStaysQuiet() throws {
        let settings = try scratchSettings()
        settings.pendingUpdate = release("1.4.0")
        settings.skippedVersion = "1.4.0"

        let update = controller(feed: StubFeed(.success(release("1.4.0"))), settings: settings)
        update.restorePendingUpdate()

        XCTAssertEqual(update.state, .idle)
    }

    /// Dismissing is "not now"; skipping is "never". The first should come back next launch.
    func testDismissingKeepsTheUpdateAndSkippingForgetsIt() throws {
        let settings = try scratchSettings()
        let update = controller(feed: StubFeed(.success(release("1.4.0"))), settings: settings)
        update.check(manual: true)
        settle()

        update.dismiss()
        XCTAssertEqual(update.state, .idle)
        XCTAssertEqual(settings.pendingUpdate, release("1.4.0"),
                       "dismissing the pill should not forget the update")

        let next = controller(feed: StubFeed(.success(release("1.4.0"))), settings: settings)
        next.restorePendingUpdate()
        XCTAssertEqual(next.state, .available(release("1.4.0")))

        next.skip(release("1.4.0"))
        XCTAssertNil(settings.pendingUpdate, "skipping should forget it")
    }

    /// Restoring is not gated on the preference: it costs no network, and an update the reader has
    /// already been shown should not disappear because automatic checks are off.
    func testRestoringWorksEvenWithAutomaticChecksOff() throws {
        let settings = try scratchSettings()
        settings.automaticUpdateChecks = false
        settings.pendingUpdate = release("1.4.0")

        let update = controller(feed: StubFeed(.success(release("1.4.0"))), settings: settings)
        update.restorePendingUpdate()

        XCTAssertEqual(update.state, .available(release("1.4.0")))
    }

    func testAnUpToDateAnswerForgetsAnyRememberedUpdate() throws {
        let settings = try scratchSettings()
        settings.pendingUpdate = release("1.4.0")

        // GitHub now says the latest is 1.3.0 — the 1.4.0 release was pulled.
        let update = controller(feed: StubFeed(.success(release("1.3.0"))), settings: settings)
        update.check(manual: true)
        settle()

        XCTAssertEqual(update.state, .upToDate(AppVersion("1.3.0")!))
        XCTAssertNil(settings.pendingUpdate)
    }

    // MARK: Notification

    /// The badge in every window redraws off this notification, so a state change that does not
    /// post one is a badge that goes stale.
    func testEveryStateChangePostsOnceAndAnIdenticalOneDoesNot() throws {
        let update = controller(feed: StubFeed(.success(release("1.4.0"))),
                                settings: try scratchSettings())
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .folioUpdateStateChanged, object: update, queue: nil) { _ in posts += 1 }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }

        update.check(manual: true)
        settle()
        XCTAssertEqual(posts, 2, "checking, then available")

        update.setStateForTesting(.available(release("1.4.0")))
        XCTAssertEqual(posts, 2, "the same state again is not a change")

        update.dismiss()
        XCTAssertEqual(posts, 3)
    }
}
