import AppKit

/// Builds the main menu. Read-only by contract: no Edit menu, no save items.
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let main = NSMenu()

        // Folio
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Folio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenu()
        NSApp.servicesMenu = services
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Folio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Folio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Folio"))

        // File
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocumentAction(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "Open Recent")
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        recent.addItem(withTitle: "Clear Menu", action: #selector(AppDelegate.clearRecents(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        let newTab = file.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newWindowForTab(_:)), keyEquivalent: "t")
        newTab.target = nil
        file.addItem(.separator())
        let copyPath = file.addItem(withTitle: "Copy Path", action: #selector(MainWindowController.copyPath(_:)), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        file.addItem(withTitle: "Reveal in Finder", action: #selector(MainWindowController.revealInFinder(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        // Edit — the app is read-only, but Copy, Select All, and Find all need to work, and
        // none of them did before: there was no Edit menu at all.
        // The HIG rule is to disable unavailable commands, not to hide them, so nothing here
        // is conditional.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())

        // Find is unavailable while the reading pane is a stack of components: `NSTextFinder`
        // searches one text view, and there is no longer one text view holding the document.
        // The items stay, disabled, because the HIG's rule is to disable an unavailable command
        // rather than hide it — and because a document-wide find over components is the next
        // piece of work, not a decision to drop the feature.
        let find = NSMenu(title: "Find")
        for title in ["Find…", "Find Next", "Find Previous", "Use Selection for Find"] {
            let item = find.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }

        let findItem = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        main.addItem(submenu(edit, title: "Edit"))

        // View
        let view = NSMenu(title: "View")
        let showSidebar = view.addItem(withTitle: "Show Sidebar", action: #selector(MainWindowController.toggleSidebar(_:)), keyEquivalent: "s")
        showSidebar.keyEquivalentModifierMask = [.control, .command]
        view.addItem(.separator())
        let presentation = view.addItem(withTitle: "Presentation Mode", action: #selector(MainWindowController.togglePresentationMode(_:)), keyEquivalent: "p")
        presentation.keyEquivalentModifierMask = [.command, .shift]
        let fullscreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.control, .command]
        view.addItem(.separator())
        // Columns. A submenu of choices rather than a toggle: the count is decided by width,
        // but a reader on a wide screen may still prefer two roomy columns to three.
        let columns = NSMenu(title: "Columns")
        for layout in AppSettings.ColumnLayout.offered {
            let title: String
            switch layout {
            case .automatic: title = "Automatic"
            case .one: title = "One Column"
            default: title = "\(layout.displayName) Columns"
            }
            let item = columns.addItem(withTitle: title,
                                       action: #selector(MainWindowController.setColumnLayout(_:)),
                                       keyEquivalent: "\(layout.rawValue)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = layout.rawValue
        }
        let columnsItem = view.addItem(withTitle: "Columns", action: nil, keyEquivalent: "")
        columnsItem.submenu = columns
        view.addItem(withTitle: "Show Frontmatter", action: #selector(MainWindowController.toggleFrontmatter(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Render Equations", action: #selector(MainWindowController.toggleEquations(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "Bigger Text", action: #selector(MainWindowController.biggerText(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller Text", action: #selector(MainWindowController.smallerText(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(MainWindowController.actualSize(_:)), keyEquivalent: "0")
        main.addItem(submenu(view, title: "View"))

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        main.addItem(submenu(window, title: "Window"))

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Folio Help", action: nil, keyEquivalent: "?")
        NSApp.helpMenu = help
        main.addItem(submenu(help, title: "Help"))

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        menu.title = title
        return item
    }
}
