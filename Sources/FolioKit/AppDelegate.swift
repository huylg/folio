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
        windowControllers.append(wc)
        return wc
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

    @objc func clearRecents(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
        AppSettings.shared.recents = []
        // Any window still on the welcome screen is showing the list that was just cleared.
        windowControllers.forEach { $0.reloadRecents() }
    }
}
