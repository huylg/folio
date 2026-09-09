import XCTest
import Sparkle
@testable import FolioKit

final class UpdateControllerTests: XCTestCase {
    private final class StubUpdater: UpdateChecking {
        var automaticallyChecksForUpdates = true
        var canCheckForUpdates = true
        var lastUpdateCheckDate: Date? = Date()
        var starts = 0
        var backgroundChecks = 0
        var manualChecks = 0
        func start() throws { starts += 1 }
        func checkForUpdates() { manualChecks += 1 }
        func checkForUpdatesInBackground() { backgroundChecks += 1 }
    }

    private func settings() -> AppSettings {
        let suite = "folio-updater-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    private let release = Release(version: "1.11.0", pageURL: UpdateSource.releasesPageURL)

    func testLaunchChecksEvenIfSparkleCheckedRecentlyAndStartsOnlyOnce() {
        let engine = StubUpdater()
        let controller = UpdateController(updater: engine, settings: settings(), isInstalled: { true })
        controller.start()
        controller.start()
        XCTAssertEqual(engine.starts, 1)
        XCTAssertEqual(engine.backgroundChecks, 1)
    }

    func testDisabledAutomaticChecksStillAllowManualChecks() {
        let engine = StubUpdater()
        engine.automaticallyChecksForUpdates = false
        let controller = UpdateController(updater: engine, settings: settings(), isInstalled: { true })
        controller.start()
        XCTAssertEqual(engine.backgroundChecks, 0)
        controller.check(manual: true)
        XCTAssertEqual(engine.manualChecks, 1)
    }

    func testManualCheckBeforeLaunchDoesNotAlsoStartABackgroundCheck() {
        let engine = StubUpdater()
        let controller = UpdateController(updater: engine, settings: settings(), isInstalled: { true })
        controller.check(manual: true)
        XCTAssertEqual(engine.starts, 1)
        XCTAssertEqual(engine.backgroundChecks, 0)
        XCTAssertEqual(engine.manualChecks, 1)
    }

    func testSourceBuildDoesNotStartSparkle() {
        let engine = StubUpdater()
        let controller = UpdateController(updater: engine, settings: settings(), isInstalled: { false })
        controller.start()
        controller.check(manual: true)
        XCTAssertEqual(engine.starts, 0)
        XCTAssertEqual(controller.state, .failed(.notAnInstalledApp))
    }

    func testPreferenceChangesReachSparklesScheduler() {
        let engine = StubUpdater()
        let preferences = settings()
        let controller = UpdateController(updater: engine, settings: preferences, isInstalled: { true })
        controller.start()
        preferences.automaticUpdateChecks = false
        controller.automaticChecksChanged()
        XCTAssertFalse(engine.automaticallyChecksForUpdates)
        preferences.automaticUpdateChecks = true
        controller.automaticChecksChanged()
        XCTAssertTrue(engine.automaticallyChecksForUpdates)
    }

    func testDownloadPreparationAndRestartRequireSeparateUserChoices() {
        let controller = UpdateController(settings: settings())
        var downloads = 0
        var installs = 0
        controller.receiveRelease(release, stage: .notDownloaded) { choice in
            XCTAssertEqual(choice, .install)
            downloads += 1
            controller.showDownloadInitiated(cancellation: {})
        }
        XCTAssertEqual(controller.state, .available(release))
        XCTAssertEqual(downloads, 0)
        controller.download(release)
        controller.download(release)
        XCTAssertEqual(downloads, 1)
        controller.showDownloadDidReceiveExpectedContentLength(100)
        controller.showDownloadDidReceiveData(ofLength: 45)
        XCTAssertEqual(controller.state, .downloading(release, fraction: 0.45))
        controller.showDownloadDidStartExtractingUpdate()
        XCTAssertEqual(controller.state, .extracting(release, fraction: 0))
        XCTAssertTrue(controller.isBusy)
        controller.showReady(toInstallAndRelaunch: { choice in
            XCTAssertEqual(choice, .install)
            installs += 1
        })
        XCTAssertEqual(controller.state, .readyToInstall(release))
        XCTAssertEqual(installs, 0)
        controller.install()
        controller.install()
        XCTAssertEqual(installs, 1)
    }

    func testDownloadProgressHandlesUnknownAndIncorrectLengths() {
        let controller = UpdateController(settings: settings())
        controller.receiveRelease(release, stage: .notDownloaded, reply: { _ in })
        controller.showDownloadInitiated(cancellation: {})
        controller.showDownloadDidReceiveData(ofLength: 100)
        XCTAssertEqual(controller.state, .downloading(release, fraction: 0))
        controller.showDownloadDidReceiveExpectedContentLength(50)
        XCTAssertEqual(controller.state, .downloading(release, fraction: 1))
    }

    func testCancelIsUnavailableOnceExtractionBegins() {
        let controller = UpdateController(settings: settings())
        var cancellations = 0
        controller.receiveRelease(release, stage: .notDownloaded, reply: { _ in })
        controller.showDownloadInitiated(cancellation: { cancellations += 1 })
        controller.showDownloadDidStartExtractingUpdate()
        controller.cancelDownload()
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(controller.state, .extracting(release, fraction: 0))
    }

    func testCancelDownloadCallsSparkleOnce() {
        let controller = UpdateController(settings: settings())
        var cancellations = 0
        controller.receiveRelease(release, stage: .notDownloaded, reply: { _ in })
        controller.showDownloadInitiated(cancellation: { cancellations += 1 })
        controller.cancelDownload()
        controller.cancelDownload()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testSkipAndDismissReturnTheCorrectChoiceToSparkle() {
        for skip in [true, false] {
            let controller = UpdateController(settings: settings())
            var choices: [SPUUserUpdateChoice] = []
            controller.receiveRelease(release, stage: .notDownloaded) { choices.append($0) }
            if skip { controller.skip(release) } else { controller.dismiss() }
            controller.dismiss()
            XCTAssertEqual(choices, [skip ? .skip : .dismiss])
            XCTAssertEqual(controller.state, .idle)
        }
    }

    func testResumedInstallationOffersRestartAndDoesNotDownloadAgain() {
        let controller = UpdateController(settings: settings())
        var choices: [SPUUserUpdateChoice] = []
        controller.receiveRelease(release, stage: .installing) { choices.append($0) }
        XCTAssertEqual(controller.state, .readyToInstall(release))
        XCTAssertTrue(choices.isEmpty)
        controller.install()
        XCTAssertEqual(choices, [.install])
    }

    func testErrorAcknowledgementDoesNotEraseTheErrorBadge() {
        let controller = UpdateController(settings: settings())
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline"])
        controller.showUpdaterError(error) { controller.dismissUpdateInstallation() }
        XCTAssertEqual(controller.state, .failed(.updater("Offline")))
        controller.dismiss()
        XCTAssertEqual(controller.state, .idle)
    }

    func testLegacySkippedReleaseStaysSkippedUnlessCheckIsManual() {
        for manual in [true, false] {
            let preferences = settings()
            preferences.legacySkippedUpdate = release.version
            let controller = UpdateController(settings: preferences)
            var choices: [SPUUserUpdateChoice] = []
            controller.receiveRelease(release, stage: .notDownloaded, userInitiated: manual) {
                choices.append($0)
            }
            XCTAssertEqual(choices, manual ? [] : [.skip])
            XCTAssertEqual(controller.state, manual ? .available(release) : .idle)
            XCTAssertNil(preferences.legacySkippedUpdate)
        }
    }

    func testLatestVersionResultSurvivesSparkleTeardown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = directory.appendingPathComponent("Folio.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "io.huylg.folio.test", "CFBundleShortVersionString": "1.11.0",
        ], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        let controller = UpdateController(settings: settings(), hostBundle: bundle)
        let error = NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: [
            SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.onLatestVersion.rawValue,
        ])
        controller.showUpdateNotFoundWithError(error) { controller.dismissUpdateInstallation() }
        XCTAssertEqual(controller.state, .upToDate(AppVersion("1.11.0")!))
    }

    func testAnIncompatibleUpdateIsNotReportedAsUpToDate() {
        let controller = UpdateController(settings: settings())
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Requires newer macOS",
            SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.systemIsTooOld.rawValue,
        ])
        controller.showUpdateNotFoundWithError(error) { controller.dismissUpdateInstallation() }
        XCTAssertEqual(controller.state, .failed(.updater("Requires newer macOS")))
    }
}
