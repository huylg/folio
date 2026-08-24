import AppKit

extension Notification.Name {
    /// Posted on the main queue whenever `UpdateController.shared.state` changes.
    public static let folioUpdateStateChanged = Notification.Name("folioUpdateStateChanged")
}

/// Where an update has got to.
public enum UpdateState: Equatable {
    /// Nothing to say. The badge shows nothing at all in this state.
    case idle
    case checking
    /// Only reached by a manual check — an automatic one that finds nothing goes back to `.idle`
    /// rather than telling the reader something they did not ask about.
    case upToDate(AppVersion)
    case available(Release)
    case downloading(Release, fraction: Double)
    case readyToInstall(Release, bundle: URL)
    case installing
    case failed(UpdateError)
}

/// Drives the update: checks, downloads, and hands off to the installer.
///
/// A singleton posting through `NotificationCenter`, in the shape `AppSettings` already uses. The
/// badge in every open window listens for the same notification, so the controller never holds a
/// reference to a window and a window that opens mid-download picks up the state it finds.
public final class UpdateController {

    public static let shared = UpdateController()

    /// How long an automatic check waits before running again. A manual check ignores it.
    public static let automaticInterval: TimeInterval = 24 * 60 * 60

    private let feed: ReleaseFeed
    private let settings: AppSettings
    private let runningVersion: AppVersion?
    /// Where the app we would replace lives. A closure rather than a call to
    /// `UpdateInstaller.installedBundleURL`, because under `swift test` that is correctly nil and
    /// every decision downstream of it would be untestable.
    private let installedBundle: () -> URL?
    private var installer: UpdateInstaller?

    init(feed: ReleaseFeed = GitHubReleaseFeed(),
         settings: AppSettings = .shared,
         runningVersion: AppVersion? = AppVersion.current,
         installedBundle: @escaping () -> URL? = { UpdateInstaller.installedBundleURL }) {
        self.feed = feed
        self.settings = settings
        self.runningVersion = runningVersion
        self.installedBundle = installedBundle
    }

    public private(set) var state: UpdateState = .idle {
        didSet {
            guard state != oldValue else { return }
            NotificationCenter.default.post(name: .folioUpdateStateChanged, object: self)
        }
    }

    /// The release waiting to be downloaded or installed, whichever state we are in.
    public var pendingRelease: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .readyToInstall(let r, _): return r
        default: return nil
        }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - Checking

    /// Whether an automatic check is due. Separate from `check` so the caller can decide not to
    /// touch the network at all rather than calling in and being turned away.
    public var isAutomaticCheckDue: Bool {
        guard settings.automaticUpdateChecks == true else { return false }
        guard let last = settings.lastUpdateCheck else { return true }
        return Date().timeIntervalSince(last) >= Self.automaticInterval
    }

    /// Looks for a newer release.
    ///
    /// `manual` is the reader asking, and it overrides everything the automatic path defers to:
    /// the once-a-day throttle, a skipped version, and a `.failed` state left over from last time.
    public func check(manual: Bool) {
        guard !isBusy else { return }
        if !manual && !isAutomaticCheckDue { return }

        guard let runningVersion else {
            if manual { state = .failed(.unknownRunningVersion) }
            return
        }
        guard installedBundle() != nil else {
            if manual { state = .failed(.notAnInstalledApp) }
            return
        }

        state = .checking
        settings.lastUpdateCheck = Date()

        feed.latest { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    // A background check that cannot reach GitHub says nothing: the reader did not
                    // ask, and a badge reading "Update Failed" over a flaky café connection is
                    // noise about a thing they were not doing.
                    self.state = manual ? .failed(error) : .idle
                case .success(let release):
                    self.settle(on: release, running: runningVersion, manual: manual)
                }
            }
        }
    }

    private func settle(on release: Release, running: AppVersion, manual: Bool) {
        guard release.version > running else {
            settings.pendingUpdate = nil
            state = manual ? .upToDate(running) : .idle
            return
        }
        // Remembered before it is shown, so quitting the window the pill is in does not lose it.
        settings.pendingUpdate = release
        if !manual, settings.skippedVersion == release.version.description {
            state = .idle
            return
        }
        state = .available(release)
    }

    /// Puts back an update found on an earlier launch.
    ///
    /// Called before `check` on startup and costs no network. Without it the throttle and the
    /// forgetting compound: an update found at nine, quit at ten, is invisible until the next
    /// day's check — the app knew and threw it away.
    public func restorePendingUpdate() {
        guard case .idle = state else { return }
        guard let runningVersion, let pending = settings.pendingUpdate else { return }
        // Stale once the reader has updated by hand, or skipped it since.
        guard pending.version > runningVersion else {
            settings.pendingUpdate = nil
            return
        }
        guard settings.skippedVersion != pending.version.description else { return }
        state = .available(pending)
    }

    /// Stop offering this one. The next release supersedes it, and a manual check ignores it.
    public func skip(_ release: Release) {
        settings.skippedVersion = release.version.description
        settings.pendingUpdate = nil
        state = .idle
    }

    /// Clears the pill without forgetting the update: it comes back on the next launch, which is
    /// the difference between "not now" and "never" — `skip` is the one that means never.
    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }

    // MARK: - Downloading

    public func download(_ release: Release) {
        guard !isBusy else { return }
        state = .downloading(release, fraction: 0)

        let installer = UpdateInstaller()
        self.installer = installer
        installer.fetch(release) { [weak self] fraction in
            guard let self, case .downloading = self.state else { return }
            self.state = .downloading(release, fraction: fraction)
        } completion: { [weak self] result in
            guard let self else { return }
            self.installer = nil
            switch result {
            case .success(let bundle):
                self.state = .readyToInstall(release, bundle: bundle)
            case .failure(let error):
                self.state = .failed(error)
            }
        }
    }

    public func cancelDownload() {
        installer?.cancel()
        installer = nil
        state = .idle
    }

    // MARK: - Installing

    /// Replaces the running bundle and quits so the script can relaunch it.
    ///
    /// Returns without terminating if the swap could not be started, leaving the reason in
    /// `state` — including the read-only-location case, where the unpacked copy is revealed in the
    /// Finder for the reader to move in by hand.
    public func install() {
        guard case .readyToInstall(_, let bundle) = state else { return }
        guard let destination = installedBundle() else {
            state = .failed(.notAnInstalledApp)
            return
        }

        state = .installing
        if let error = UpdateInstaller.install(replacement: bundle, over: destination) {
            state = .failed(error)
            if case .notWritable = error {
                NSWorkspace.shared.activateFileViewerSelecting([bundle])
            }
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Test seam

    /// Lets a test drive the badge through every state without a network or a bundle.
    func setStateForTesting(_ newState: UpdateState) { state = newState }
}
