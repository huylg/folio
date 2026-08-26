import AppKit
import UniformTypeIdentifiers

public final class AppDelegate: NSObject, NSApplicationDelegate {

    public override init() { super.init() }

    private var windowControllers: [MainWindowController] = []
    private var settingsWindowController: SettingsWindowController?
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunching = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyTheme()
        NSApp.mainMenu = MainMenuBuilder.build()

        didFinishLaunching = true
        if pendingOpenURLs.isEmpty {
            makeWindowController().showWindow(nil)
        } else {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            urls.forEach { openURL($0) }
        }
        NSApp.activate(ignoringOtherApps: true)
        considerUpdates()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func application(_ application: NSApplication, open urls: [URL]) {
        if !didFinishLaunching {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        urls.forEach { openURL($0) }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    // MARK: Windows

    @discardableResult
    func makeWindowController() -> MainWindowController {
        let wc = MainWindowController()
        wc.onClose = { [weak self, weak wc] in
            guard let self, let wc else { return }
            self.windowControllers.removeAll { $0 === wc }
        }
        wc.onOpenLinkInNewTab = { [weak self, weak wc] url, anchor in
            guard let self, let wc else { return }
            self.openInNewTab(url, scrollTo: anchor, from: wc)
        }
        windowControllers.append(wc)
        return wc
    }

    /// A followed link opens beside the document it was clicked in — a tab of the same window —
    /// leaving the source document and its reading position on screen behind it.
    func openInNewTab(_ url: URL, scrollTo anchor: String? = nil, from source: MainWindowController) {
        let wc = makeWindowController()
        // Opened before the window goes on screen: the tab lands straight on its document,
        // so its navigation history — and with it the back button — starts empty.
        wc.openDocument(url, scrollTo: anchor)
        source.window?.addTabbedWindow(wc.window!, ordered: .above)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    private var keyWindowController: MainWindowController? {
        if let wc = NSApp.keyWindow?.windowController as? MainWindowController { return wc }
        return windowControllers.last
    }

    /// One document per window: an empty window takes the document, otherwise a new window
    /// opens so the one already showing something is left alone.
    func openURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            let alert = NSAlert()
            alert.messageText = "Folio opens one file at a time"
            alert.informativeText = "Choose a Markdown file rather than a folder."
            alert.runModal()
            return
        }

        let wc: MainWindowController
        if let existing = keyWindowController, existing.currentDocument == nil {
            wc = existing
        } else {
            wc = makeWindowController()
        }
        wc.openDocument(url)
        wc.showWindow(nil)
    }

    // MARK: Updates

    /// Asked once, then honoured.
    ///
    /// Folio tells the reader in its own settings that it does not reach the network unasked, so
    /// the updater asks — once, on the first launch that reaches this code — rather than defaulting
    /// itself on. `Check for Updates…` works either way, so declining costs nothing but the
    /// automatic check.
    private func considerUpdates() {
        // Nothing to update from a `swift run` build or under the test runner, and no reason to
        // put the question to anyone running one.
        guard UpdateInstaller.installedBundleURL != nil else { return }

        // First, put back anything found on an earlier launch. This is deliberately not behind
        // the automatic-checks preference: it touches no network, and an update the reader has
        // already been told about should not vanish because they quit the app.
        UpdateController.shared.restorePendingUpdate()

        guard AppSettings.shared.automaticUpdateChecks != nil else {
            askAboutAutomaticUpdates()
            return
        }
        UpdateController.shared.check(manual: false)
    }

    private func askAboutAutomaticUpdates() {
        let alert = NSAlert()
        alert.messageText = "Check for updates automatically?"
        alert.informativeText =
            "Folio can look for a new version once a day, over HTTPS from its GitHub releases "
            + "page. Nothing about your documents is sent.\n\n"
            + "You can change this later in Settings › Advanced, and Folio › Check for Updates… "
            + "works either way."
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don’t Check")
        let automatic = alert.runModal() == .alertFirstButtonReturn
        AppSettings.shared.automaticUpdateChecks = automatic
        if automatic { UpdateController.shared.check(manual: false) }
    }

    // MARK: Actions

    @objc func newWindow(_ sender: Any?) {
        let wc = makeWindowController()
        wc.showWindow(nil)
    }

    @objc func newWindowForTab(_ sender: Any?) {
        guard let current = keyWindowController else { newWindow(sender); return }
        let wc = makeWindowController()
        current.window?.addTabbedWindow(wc.window!, ordered: .above)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openDocumentAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 12.0, *) {
            var types: [UTType] = [.plainText]
            if let md = UTType(filenameExtension: "md") { types.append(md) }
            if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
            panel.allowedContentTypes = types
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openURL(url)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateController.shared.check(manual: true)
    }

    @objc func clearRecents(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
        AppSettings.shared.recents = []
        // Any window still on the welcome screen is showing the list that was just cleared.
        windowControllers.forEach { $0.reloadRecents() }
    }
}
