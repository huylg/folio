import AppKit
import Sparkle

extension Notification.Name {
    public static let folioUpdateStateChanged = Notification.Name("folioUpdateStateChanged")
}

public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(AppVersion)
    case available(Release)
    case downloading(Release, fraction: Double)
    case extracting(Release, fraction: Double)
    case readyToInstall(Release)
    case installing
    case failed(UpdateError)
}

/// The small part of Sparkle needed by our controls, replaceable in lifecycle tests.
protocol UpdateChecking: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    func start() throws
    func checkForUpdates()
    func checkForUpdatesInBackground()
}

extension SPUUpdater: UpdateChecking {}

/// Sparkle owns scheduling, downloads, verification and replacement. This controller only
/// connects its user-driver callbacks to Folio's titlebar and settings.
public final class UpdateController: NSObject {
    public static let shared = UpdateController()
    private var updater: UpdateChecking?
    private let settings: AppSettings
    private let hostBundle: Bundle
    private let isInstalled: () -> Bool
    private var started = false
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var release: Release?
    private lazy var standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
    private var usesStandardUI = false

    init(updater: UpdateChecking? = nil, settings: AppSettings = .shared,
         hostBundle: Bundle = .main, isInstalled: (() -> Bool)? = nil) {
        self.updater = updater
        self.settings = settings
        self.hostBundle = hostBundle
        self.isInstalled = isInstalled ?? {
            hostBundle.bundleURL.pathExtension == "app"
                && hostBundle.bundleIdentifier == "io.huylg.folio"
        }
        super.init()
    }

    public private(set) var state: UpdateState = .idle {
        didSet {
            if state != oldValue {
                NotificationCenter.default.post(name: .folioUpdateStateChanged, object: self)
            }
        }
    }

    public var pendingRelease: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .extracting(let r, _),
             .readyToInstall(let r): return r
        default: return nil
        }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .extracting, .installing: return true
        default: return false
        }
    }

    public var lastUpdateCheck: Date? { updater?.lastUpdateCheckDate }

    /// Force one launch check after starting, as recommended by Sparkle. Subsequent hourly
    /// checks are scheduled by Sparkle, including for apps that stay open for days.
    public func start(checkOnLaunch: Bool = true) {
        guard !started, isInstalled() else { return }
        settings.migrateUpdateSettings()
        if updater == nil {
            guard let key = hostBundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                  Data(base64Encoded: key)?.count == 32 else {
                state = .failed(.configuration("This build has no Sparkle update signing key."))
                return
            }
            updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle,
                                 userDriver: self, delegate: nil)
        }
        do {
            try updater?.start()
            started = true
            if checkOnLaunch, updater?.automaticallyChecksForUpdates == true {
                updater?.checkForUpdatesInBackground()
            }
        } catch {
            state = .failed(.updater(error.localizedDescription))
        }
    }

    /// Call only in response to a user preference change, so Sparkle can reset its schedule.
    public func automaticChecksChanged() {
        guard started else { start(); return }
        updater?.automaticallyChecksForUpdates = settings.automaticUpdateChecks == true
    }

    public func check(manual: Bool) {
        guard manual else { return } // Scheduled checks belong exclusively to Sparkle.
        guard isInstalled() else { state = .failed(.notAnInstalledApp); return }
        start(checkOnLaunch: false)
        guard started else { return }
        showUpdateInFocus()
        if updater?.canCheckForUpdates == true { updater?.checkForUpdates() }
    }

    public func download(_ release: Release) {
        guard case .available(let offered) = state, release == offered else { return }
        respond(.install)
    }

    public func install() {
        if case .readyToInstall = state { respond(.install) }
        else if case .installing = state { retryTermination?() }
    }

    public func skip(_ release: Release) {
        guard case .available(let offered) = state, release == offered else { return }
        respond(.skip)
        state = .idle
    }

    public func dismiss() {
        guard !isBusy else { return }
        respond(.dismiss)
        state = .idle
    }

    public func cancelDownload() {
        guard case .downloading = state else { return }
        let cancel = cancellation
        cancellation = nil
        cancel?()
        state = .idle
    }

    private func respond(_ response: SPUUserUpdateChoice) {
        let reply = choice
        choice = nil // Sparkle can synchronously provide the next callback.
        reply?(response)
    }

    func setStateForTesting(_ state: UpdateState) { self.state = state }
}

extension UpdateController: SPUUserDriver {
    public func show(_ request: SPUUpdatePermissionRequest,
                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        state = .checking
    }

    public func showUpdateFound(with item: SUAppcastItem, state updateState: SPUUserUpdateState,
                                reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Let Sparkle present special upgrade/information-only notices correctly. Folio's
        // ordinary releases have a downloadable archive and use the titlebar.
        usesStandardUI = item.isInformationOnlyUpdate || item.isMajorUpgrade
        if usesStandardUI {
            standard.showUpdateFound(with: item, state: updateState, reply: reply)
            return
        }
        receiveRelease(Release(version: item.displayVersionString,
                               pageURL: item.fullReleaseNotesURL ?? item.releaseNotesURL ?? UpdateSource.releasesPageURL),
                       stage: updateState.stage, userInitiated: updateState.userInitiated, reply: reply)
    }

    func receiveRelease(_ release: Release, stage: SPUUserUpdateStage, userInitiated: Bool = false,
                        reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let skipped = settings.legacySkippedUpdate
        settings.legacySkippedUpdate = nil
        if !userInitiated, skipped == release.version {
            reply(.skip)
            return
        }
        self.release = release
        cancellation = nil
        choice = reply
        state = stage == .installing ? .readyToInstall(release) : .available(release)
    }

    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if usesStandardUI { standard.showUpdateReleaseNotes(with: downloadData) }
    }
    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        if usesStandardUI { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    public func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // Preserve Sparkle's explanation (including unsupported macOS versions) instead of
        // incorrectly reporting every "no compatible update" as "up to date".
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        if let reason, [SPUNoUpdateFoundReason.onLatestVersion.rawValue,
                        SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue].contains(reason),
           let version = AppVersion.fromBundle(hostBundle) {
            state = .upToDate(version)
        } else {
            state = .failed(.updater(error.localizedDescription))
        }
        acknowledgement()
    }

    public func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state = .failed(.updater(error.localizedDescription))
        if usesStandardUI { standard.showUpdaterError(error, acknowledgement: acknowledgement) }
        else { acknowledgement() }
    }

    public func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedBytes = 0
        receivedBytes = 0
        if let release { state = .downloading(release, fraction: 0) }
        if usesStandardUI { standard.showDownloadInitiated(cancellation: cancellation) }
    }
    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        updateDownloadProgress()
        if usesStandardUI { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    }
    public func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        updateDownloadProgress()
        if usesStandardUI { standard.showDownloadDidReceiveData(ofLength: length) }
    }
    private func updateDownloadProgress() {
        guard let release else { return }
        let fraction = expectedBytes == 0 ? 0 : min(1, Double(receivedBytes) / Double(expectedBytes))
        state = .downloading(release, fraction: fraction)
    }
    public func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        if let release { state = .extracting(release, fraction: 0) }
        if usesStandardUI { standard.showDownloadDidStartExtractingUpdate() }
    }
    public func showExtractionReceivedProgress(_ progress: Double) {
        if let release { state = .extracting(release, fraction: min(1, max(0, progress))) }
        if usesStandardUI { standard.showExtractionReceivedProgress(progress) }
    }
    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if usesStandardUI { standard.showReady(toInstallAndRelaunch: reply); return }
        choice = reply
        if let release { state = .readyToInstall(release) }
    }
    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                     retryTerminatingApplication: @escaping () -> Void) {
        state = .installing
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        if usesStandardUI {
            standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                           retryTerminatingApplication: retryTerminatingApplication)
        }
    }
    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
                                                acknowledgement: @escaping () -> Void) {
        state = .idle
        acknowledgement()
    }
    public func dismissUpdateInstallation() {
        choice = nil
        cancellation = nil
        retryTermination = nil
        release = nil
        if usesStandardUI { standard.dismissUpdateInstallation() }
        usesStandardUI = false
        // Sparkle tears down immediately after acknowledgement; keep the outcome readable.
        switch state {
        case .failed, .upToDate: break
        default: state = .idle
        }
    }
    public func showUpdateInFocus() {
        if usesStandardUI { standard.showUpdateInFocus(); return }
        guard let app = NSApp else { return }
        app.activate(ignoringOtherApps: true)
        if let window = app.windows.first(where: { $0.windowController is MainWindowController }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            (app.delegate as? AppDelegate)?.newWindow(nil)
        }
    }
}
