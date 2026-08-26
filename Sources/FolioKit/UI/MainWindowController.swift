import AppKit

/// One window, one document.
///
/// Two screens, one at a time: the welcome screen until a document is open, then the reading
/// screen — an outline sidebar and the rendered document. Opening a document navigates one way,
/// the back button the other. There is no folder browser and no cross-file search.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {

    // MARK: State
    private(set) var currentDocument: MarkdownDocument?
    private var presentationMode = false

    /// Which screen the window is showing. `openDocument` moves one way, `goBack` the other.
    private(set) var showsDocumentScreen = false
    /// Whether the outline's opening width has been set, which happens once per window.
    private var didPlaceSidebar = false

    var onClose: (() -> Void)?

    // MARK: View controllers
    private let splitVC = NSSplitViewController()
    let welcomeVC = WelcomeViewController()
    let outlineVC = OutlineViewController()
    let documentVC = DocumentViewController()

    private var outlineItem: NSSplitViewItem!

    /// Comfortable opening size: wide enough for the outline plus a full reading column.
    static let defaultContentSize = NSSize(width: 1080, height: 780)
    /// Floor that keeps the outline and the document both above their own minimums.
    static let minimumContentSize = NSSize(width: 720, height: 480)
    private static let frameAutosaveName = "FolioMainWindow"

    /// Under `swift test` the window frame is not autosaved, so a test's geometry can never
    /// become the app's remembered frame.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "FolioMain"
        // Set before any frame restore so AppKit clamps to it rather than honouring a
        // degenerate saved frame.
        window.contentMinSize = Self.minimumContentSize

        if Self.isRunningTests {
            window.center()
        } else {
            window.setFrameAutosaveName(Self.frameAutosaveName)
            if !window.setFrameUsingName(Self.frameAutosaveName) {
                window.center()
            }
            // A remembered frame can still be unusable — saved on a larger display, or written
            // by an earlier build. Fall back to the default rather than opening a sliver.
            let restored = window.contentRect(forFrameRect: window.frame).size
            if restored.width < Self.minimumContentSize.width
                || restored.height < Self.minimumContentSize.height {
                window.setContentSize(Self.defaultContentSize)
                window.center()
            }
        }

        super.init(window: window)
        window.delegate = self

        // Keep the toolbar/titlebar strip present on both screens. The welcome toolbar is empty,
        // but using the same unified chrome prevents the titlebar from changing height when a
        // document opens.
        installToolbar(forDocument: false)

        // The update pill lives in the titlebar rather than the toolbar so it survives the
        // toolbar swap between the welcome and document screens. The window owns it from here.
        window.addTitlebarAccessoryViewController(UpdateBadgeAccessoryController())

        outlineItem = NSSplitViewItem(sidebarWithViewController: outlineVC)
        outlineItem.minimumThickness = 200
        outlineItem.maximumThickness = 360
        // Opens at its full width. A fifth of the window landed on the 200pt minimum, where a
        // converted book's headings — "Operability: Making Life Easy for Operations" — are all
        // truncated to the point of being unreadable.
        outlineItem.preferredThicknessFraction = 0.34
        outlineItem.canCollapse = true

        let contentItem = NSSplitViewItem(viewController: documentVC)
        contentItem.minimumThickness = 420

        splitVC.addSplitViewItem(outlineItem)
        splitVC.addSplitViewItem(contentItem)
        install(welcomeVC)

        wireCallbacks()
        updateTitle()

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .folioSettingsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification, object: splitVC.splitView
        )
        watchForDividerPress()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        dragWatch?.invalidate()
        if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
    }

    private func wireCallbacks() {
        outlineVC.onSelect = { [weak self] anchor in self?.documentVC.scrollTo(anchor: anchor) }
        outlineVC.onPreviewContent = { [weak self] index in
            self?.documentVC.sectionPreview(forOutlineIndex: index)
        }
        documentVC.onHeadingChange = { [weak self] index in
            self?.outlineVC.highlight(index: index)
        }
        documentVC.onVisibleSectionsChange = { [weak self] indices in
            self?.outlineVC.markVisible(indices)
        }
        documentVC.onOpenRelativeLink = { [weak self] url, fragment in
            self?.openDocument(url, scrollTo: fragment)
        }
        welcomeVC.onOpenDocument = {
            NSApp.sendAction(#selector(AppDelegate.openDocumentAction(_:)), to: nil, from: nil)
        }
        welcomeVC.onOpenRecent = { [weak self] url in self?.openDocument(url) }
    }

    // MARK: Opening

    /// `scrollTo` carries the fragment from a `foo.md#section` link.
    func openDocument(_ url: URL, scrollTo anchor: String? = nil) {
        do {
            let doc = try MarkdownDocument(url: url)
            currentDocument = doc
            // Before the render, not after: the reading pane decides its column count from its
            // own width, and on the welcome screen it has not been laid out at all.
            showDocumentScreen()
            documentVC.render(document: doc)
            outlineVC.update(document: doc)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            AppSettings.shared.noteRecent(url)
            updateTitle()
            if let anchor {
                // After the first layout pass, so the target's position is real.
                DispatchQueue.main.async { [weak self] in
                    self?.documentVC.scrollTo(anchor: anchor)
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open document"
            alert.informativeText = "\(url.lastPathComponent): \(error.localizedDescription)"
            alert.runModal()
        }
    }

    // MARK: Navigating between the screens

    /// Leaves the welcome screen for the reading screen.
    ///
    /// A screen swap rather than unhiding a view: the sidebar, the toolbar controls, and the
    /// reading pane all belong to the document, and none has anything to show until there is one.
    private func showDocumentScreen() {
        guard let window, !showsDocumentScreen else { return }
        showsDocumentScreen = true
        install(splitVC)
        installToolbar(forDocument: true)
        // Laid out here so the pane has its real width — and its inset under the toolbar —
        // before the document is rendered into it.
        window.layoutIfNeeded()
        // `preferredThicknessFraction` is a hint AppKit is free to ignore for a sidebar, and it
        // did: the outline opened on its 200pt minimum. The divider is placed explicitly once the
        // window has its real width — the first time only, so coming back to a document does not
        // undo a width the reader dragged for themselves.
        if !didPlaceSidebar {
            didPlaceSidebar = true
            DispatchQueue.main.async { [weak self] in self?.openSidebarAtFullWidth() }
        }
        fadeIn(splitVC.view)
    }

    /// Back to the welcome screen, leaving the document behind.
    ///
    /// The window ends up as a fresh one does — no document, no outline, and no document controls
    /// in the toolbar — which also makes it available again to `AppDelegate`'s "an empty window
    /// takes the document" rule, rather than a spare window nothing will ever reuse.
    private func showWelcomeScreen() {
        guard showsDocumentScreen else { return }
        // Presentation mode is a way of reading a document, so leaving the document leaves it:
        // full screen with the welcome screen in it is not a state worth being able to reach.
        if presentationMode { togglePresentationMode(nil) }
        showsDocumentScreen = false
        currentDocument = nil
        outlineVC.clear()
        // Before the swap, so document controls are never seen over the welcome screen. An empty
        // unified toolbar remains to keep the titlebar consistent with the document screen.
        installToolbar(forDocument: false)
        welcomeVC.reloadRecents()
        install(welcomeVC)
        updateTitle()
        fadeIn(welcomeVC.view)
    }

    /// Puts a screen in the window without letting it resize the window.
    ///
    /// Setting `contentViewController` resizes the window to the incoming view's frame, which on
    /// a swap means the reader's window jumps to whatever size a screen happened to be built at.
    private func install(_ screen: NSViewController) {
        guard let window else { return }
        let frame = window.frame
        screen.view.frame = NSRect(origin: .zero,
                                   size: window.contentRect(forFrameRect: frame).size)
        window.contentViewController = screen
        window.setFrame(frame, display: false)
    }

    /// The arriving screen fades up, so the swap reads as one move rather than a cut.
    private func fadeIn(_ view: NSView) {
        guard !Self.isRunningTests else { return }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            view.animator().alphaValue = 1
        }, completionHandler: { view.alphaValue = 1 })
    }

    private func updateTitle() {
        guard let window else { return }
        guard let doc = currentDocument else {
            window.title = "Folio"
            window.subtitle = ""
            window.representedURL = nil
            return
        }
        window.title = doc.url.lastPathComponent
        window.subtitle = ""
        // Gives the titlebar its proxy icon, ⌘-click path popover, and drag-out.
        window.representedURL = doc.url
    }

    // MARK: Window delegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// The recents list is shared, so a window sitting on the welcome screen while another one
    /// opened something has a stale list until it is looked at again.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !showsDocumentScreen else { return }
        welcomeVC.reloadRecents()
    }

    // MARK: Toolbar

    private static let welcomeToolbarIdentifier = NSToolbar.Identifier("FolioWelcomeToolbar")
    private static let documentToolbarIdentifier = NSToolbar.Identifier("FolioDocumentToolbar")

    /// The sidebar toggle, built explicitly rather than left to the system identifier.
    ///
    /// `.toggleSidebar` produced no item at all here, which left a collapsed sidebar with no way
    /// back except the menu — the toolbar was empty. An item of our own is always there, and it is
    /// the button that reopens the sidebar.
    static let sidebarItemIdentifier = NSToolbarItem.Identifier("folioToggleSidebar")

    /// The way back to the welcome screen.
    static let backItemIdentifier = NSToolbarItem.Identifier("folioBack")

    /// The back button sits *after* the tracking separator, over the document rather than over
    /// the outline: it is the reading screen the reader is leaving, not the sidebar.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        guard toolbar.identifier == Self.documentToolbarIdentifier else { return [] }
        return [Self.sidebarItemIdentifier, .sidebarTrackingSeparator, Self.backItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.isNavigational = true
        switch identifier {
        case Self.sidebarItemIdentifier:
            item.image = NSImage(systemSymbolName: "sidebar.leading",
                                 accessibilityDescription: "Show or hide the outline")
            item.label = "Sidebar"
            item.toolTip = "Show or hide the outline"
            item.action = #selector(toggleSidebar(_:))
        case Self.backItemIdentifier:
            item.image = NSImage(systemSymbolName: "chevron.backward",
                                 accessibilityDescription: "Back to the welcome screen")
            item.label = "Back"
            item.toolTip = "Back to the welcome screen"
            item.action = #selector(goBack(_:))
        default:
            return nil
        }
        return item
    }

    /// Installs chrome for a screen. Both toolbars use the window's unified style, so navigation
    /// never changes the titlebar's height or material; the welcome variant is simply empty.
    ///
    /// Replacing rather than editing in place matters because a toolbar reads its default items
    /// once, when it is attached to the window.
    private func installToolbar(forDocument: Bool) {
        guard let window else { return }
        let identifier = forDocument
            ? Self.documentToolbarIdentifier
            : Self.welcomeToolbarIdentifier
        guard window.toolbar?.identifier != identifier else { return }
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    // MARK: Actions

    @objc func toggleSidebar(_ sender: Any?) {
        guard showsDocumentScreen else { return }
        splitVC.toggleSidebar(sender)
    }

    @objc func goBack(_ sender: Any?) {
        showWelcomeScreen()
    }

    /// Re-reads the recents list, for a change made from somewhere else — clearing them.
    func reloadRecents() {
        guard !showsDocumentScreen else { return }
        welcomeVC.reloadRecents()
    }

    /// Opens the outline at its full width.
    func openSidebarAtFullWidth() {
        guard showsDocumentScreen, let window, let outlineItem, !outlineItem.isCollapsed,
              splitVC.splitView.arrangedSubviews.count > 1
        else { return }
        let content = window.contentRect(forFrameRect: window.frame).width
        let target = min(outlineItem.maximumThickness,
                         max(outlineItem.minimumThickness, content * 0.34))
        splitVC.splitView.setPosition(target, ofDividerAt: 0)
    }

    // MARK: Dragging the divider shut

    // A divider drag is two gestures wearing one costume. Up to the outline's minimum width it
    // resizes; carried on past that, it is a request to close. AppKit does answer the second one
    // — it collapses the sidebar the moment the drag goes far enough — but it answers it by making
    // the sidebar vanish between one frame and the next, while the toolbar button beside it closes
    // the same sidebar with an animation. Two ways to do one thing, and the direct one looks
    // broken.
    //
    // So AppKit's snap is switched off for the length of the drag and the closing is done here,
    // through `toggleSidebar` — the button's animation, from the button's code path.
    //
    // Switching it off has to happen before the split view's `mouseDown`, which is why there is an
    // event monitor for it: `NSSplitView` reads collapsibility when the drag begins, so a flag
    // flipped once the drag is under way arrives too late and the sidebar still snaps.

    /// Whether the pointer is held down: a drag, as opposed to a window resize or an animation.
    ///
    /// Injected, with `pointerX`, because a synthesized drag does not survive `NSSplitView`'s own
    /// event tracking — the tracking loop reads one event and stops — so a test stands in for the
    /// hand instead.
    static var isPointerDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// The pointer's x in the split view's coordinates.
    static var pointerX: (NSSplitView) -> CGFloat = { splitView in
        guard let window = splitView.window else { return .greatestFiniteMagnitude }
        return splitView.convert(window.mouseLocationOutsideOfEventStream, from: nil).x
    }

    /// How far past the outline's minimum width the pointer goes before the drag counts as
    /// closing. Half the minimum, which is roughly where AppKit's own snap sits.
    private var closingPoint: CGFloat { (outlineItem?.minimumThickness ?? 200) / 2 }

    /// How far from the divider the pointer may be for a press or a resize to count as a drag.
    ///
    /// Tight, roughly AppKit's own grab area for a thin divider: a press further out is somebody
    /// clicking in the page, and a selection dragged left from there would otherwise read as
    /// closing the sidebar.
    private static let dividerGrabSlack: CGFloat = 6

    /// Takes over the drag before `NSSplitView` starts tracking it.
    private func watchForDividerPress() {
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            if let self, event.window === self.window { self.beginDividerDrag(ifNear: true) }
            return event
        }
    }

    /// A drag can also be noticed from the resize it causes, for the case where the press was
    /// missed — the sidebar is then closed on release, which is all the watch needs.
    @objc private func splitViewDidResize(_ note: Notification) {
        guard Self.isPointerDown() else { return }
        beginDividerDrag(ifNear: true)
    }

    /// Holds off AppKit's snap and starts watching, if the pointer is on the divider.
    private func beginDividerDrag(ifNear near: Bool) {
        guard showsDocumentScreen, dragWatch == nil, let outlineItem, !outlineItem.isCollapsed
        else { return }
        // The pointer has to be on the divider. Dragging the window's own left edge resizes the
        // split view too, and lands the pointer at x = 0 — which would read as closing.
        let divider = sidebarThickness + splitVC.splitView.dividerThickness / 2
        guard !near || abs(Self.pointerX(splitVC.splitView) - divider) < Self.dividerGrabSlack
        else { return }

        outlineItem.canCollapse = false
        var closeRequested = false
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, let outlineItem = self.outlineItem else { return timer.invalidate() }
            if Self.pointerX(self.splitVC.splitView) < self.closingPoint { closeRequested = true }
            guard !Self.isPointerDown() else { return }
            timer.invalidate()
            self.dragWatch = nil
            outlineItem.canCollapse = true
            // On release rather than mid-drag: the split view is still tracking the divider until
            // the hand comes up, and an animation running against that tracking fights it.
            if closeRequested, !outlineItem.isCollapsed { self.toggleSidebar(nil) }
        }
        dragWatch = timer
        // The common modes because `NSSplitView` tracks the drag in its own event loop: a timer
        // scheduled the ordinary way would not fire until the drag was already over.
        RunLoop.current.add(timer, forMode: .common)
    }

    private var dragWatch: Timer?
    private var pressMonitor: Any?

    /// The outline's thickness as the divider measures it — the split view's own coordinates,
    /// which are 8pt wider than the outline's view: a sidebar item insets its content.
    private var sidebarThickness: CGFloat {
        splitVC.splitView.arrangedSubviews.first?.frame.width ?? 0
    }

    private var sidebarCollapsed: Bool { outlineItem?.isCollapsed ?? false }

    @objc func togglePresentationMode(_ sender: Any?) {
        presentationMode.toggle()
        let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
        if presentationMode {
            if !fullScreen { window?.toggleFullScreen(nil) }
            outlineItem.isCollapsed = true
            documentVC.setTextScale(1.35)
        } else {
            if fullScreen { window?.toggleFullScreen(nil) }
            outlineItem.isCollapsed = false
            documentVC.setTextScale(1.0)
        }
    }

    @objc func setColumnLayout(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        AppSettings.shared.columnLayout = AppSettings.ColumnLayout(rawValue: item.tag)
    }

    @objc func toggleFrontmatter(_ sender: Any?) {
        AppSettings.shared.showFrontmatter.toggle()
    }

    @objc func toggleEquations(_ sender: Any?) {
        AppSettings.shared.renderEquations.toggle()
    }

    @objc func biggerText(_ sender: Any?) { AppSettings.shared.textSize += 1 }
    @objc func smallerText(_ sender: Any?) { AppSettings.shared.textSize -= 1 }
    @objc func actualSize(_ sender: Any?) {
        AppSettings.shared.textSize = AppSettings.defaultTextSize
    }

    @objc func copyPath(_ sender: Any?) {
        guard let url = currentDocument?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = currentDocument?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func settingsChanged() {
        guard let doc = currentDocument else { return }
        // The reflow moves every section; a peek card anchored to the old layout would lie.
        outlineVC.cancelPreview()
        documentVC.applySettingsLive()
        documentVC.render(document: doc, preserveScroll: true)
    }

    // MARK: Menu validation

    /// Unavailable commands are disabled, not hidden, per the HIG.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSidebar(_:)):
            menuItem.title = sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return showsDocumentScreen
        case #selector(goBack(_:)):
            return showsDocumentScreen
        case #selector(setColumnLayout(_:)):
            menuItem.state = menuItem.tag == AppSettings.shared.columnLayout.rawValue
                ? .on : .off
            return currentDocument != nil
        case #selector(toggleFrontmatter(_:)):
            menuItem.state = AppSettings.shared.showFrontmatter ? .on : .off
            return currentDocument != nil
        case #selector(toggleEquations(_:)):
            menuItem.state = AppSettings.shared.renderEquations ? .on : .off
            return currentDocument != nil
        case #selector(togglePresentationMode(_:)):
            menuItem.state = presentationMode ? .on : .off
            return currentDocument != nil
        case #selector(copyPath(_:)), #selector(revealInFinder(_:)):
            return currentDocument != nil
        default:
            return true
        }
    }
}
