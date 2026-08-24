import AppKit

/// Hangs the update badge off the window's titlebar.
///
/// A titlebar accessory rather than a toolbar item, because the welcome screen has no toolbar —
/// `showWelcomeScreen()` sets `window.toolbar = nil` — and a toolbar item would therefore vanish on
/// the one screen a reader with no document open is looking at. An accessory belongs to the window
/// and survives the swap between the two screens.
final class UpdateBadgeAccessoryController: NSTitlebarAccessoryViewController {

    private let badge = UpdateBadgeView(frame: .zero)
    private let controller: UpdateController

    /// Exposed for the tests, which assert on the title the badge is showing.
    var badgeView: UpdateBadgeView { badge }

    init(controller: UpdateController = .shared) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Space between the pill and the trailing edge of the titlebar.
    private static let trailingInset: CGFloat = 10

    override func loadView() {
        let container = NSView()
        badge.target = self
        badge.action = #selector(badgeClicked)
        badge.menuProvider = { [weak self] in self?.contextMenu() }
        container.addSubview(badge)
        view = container

        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: .folioUpdateStateChanged, object: nil)
        refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func stateChanged() { refresh() }

    /// The badge and the accessory are hidden together: hiding only the badge would leave the
    /// titlebar reserving space for a pill that is not there.
    private func refresh() {
        guard isViewLoaded else { return }
        badge.apply(controller.state)
        isHidden = badge.isHidden
        resizeToFitBadge()
    }

    /// Sizes the accessory to its content by hand.
    ///
    /// A titlebar accessory is positioned by AppKit from its view's *frame*, and AppKit never
    /// consults the view's fitting size to set one. Left to autolayout the container came out
    /// 0pt wide with a correct 153pt `fittingSize` beside it — a pill that was present, laid out,
    /// unhidden, and invisible. So the width is set here, and the badge is placed inside it,
    /// rather than being asked for through constraints that nothing resolves.
    private func resizeToFitBadge() {
        guard isViewLoaded else { return }
        let size = badge.intrinsicContentSize
        badge.frame = NSRect(x: 0,
                             y: ((view.frame.height - size.height) / 2).rounded(),
                             width: size.width,
                             height: size.height)
        view.frame.size.width = badge.isHidden ? 0 : size.width + Self.trailingInset
    }

    /// The titlebar sets the accessory's height, so the badge is re-centred whenever it changes.
    override func viewDidLayout() {
        super.viewDidLayout()
        resizeToFitBadge()
    }

    // MARK: Actions

    /// One click advances whatever the state is; a secondary click opens the menu, which is where
    /// skipping, cancelling, and the release notes live. A state with nothing to advance *to* —
    /// a download already running — opens the menu on a plain click too, so the pill is never
    /// inert when clicked.
    @objc private func badgeClicked() {
        switch controller.state {
        case .available(let release):
            controller.download(release)
        case .readyToInstall:
            controller.install()
        case .failed:
            controller.check(manual: true)
        case .upToDate:
            controller.dismiss()
        case .downloading, .installing, .checking, .idle:
            showMenu()
        }
    }

    private func showMenu() {
        guard let menu = contextMenu() else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: badge.bounds.height + 4),
                   in: badge)
    }

    /// Nil when there is nothing to offer, so a right-click on a pill with no actions does not
    /// flash an empty menu.
    private func contextMenu() -> NSMenu? {
        let menu = NSMenu()

        if let release = controller.pendingRelease {
            let notes = menu.addItem(withTitle: "What’s New in \(release.version)…",
                                     action: #selector(openReleaseNotes), keyEquivalent: "")
            notes.target = self
            menu.addItem(.separator())
        }

        switch controller.state {
        case .available:
            let skip = menu.addItem(withTitle: "Skip This Version",
                                    action: #selector(skipVersion), keyEquivalent: "")
            skip.target = self
        case .downloading:
            let cancel = menu.addItem(withTitle: "Cancel Download",
                                      action: #selector(cancelDownload), keyEquivalent: "")
            cancel.target = self
        case .failed(let error):
            let reason = menu.addItem(withTitle: error.message, action: nil, keyEquivalent: "")
            reason.isEnabled = false
            let retry = menu.addItem(withTitle: "Try Again",
                                     action: #selector(retry), keyEquivalent: "")
            retry.target = self
        default:
            break
        }

        if !controller.isBusy {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let dismiss = menu.addItem(withTitle: "Dismiss",
                                       action: #selector(dismissBadge), keyEquivalent: "")
            dismiss.target = self
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func openReleaseNotes() {
        guard let release = controller.pendingRelease else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    @objc private func skipVersion() {
        guard case .available(let release) = controller.state else { return }
        controller.skip(release)
    }

    @objc private func cancelDownload() { controller.cancelDownload() }
    @objc private func retry() { controller.check(manual: true) }
    @objc private func dismissBadge() { controller.dismiss() }
}
