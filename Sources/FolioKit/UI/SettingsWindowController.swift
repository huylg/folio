import AppKit

/// Settings window with toolbar-style tabs: General · Appearance · Markdown · Advanced.
final class SettingsWindowController: NSWindowController {

    init() {
        let tabVC = NSTabViewController()
        tabVC.tabStyle = .toolbar

        let general = GeneralPane()
        general.title = "General"
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)

        let appearance = AppearancePane()
        appearance.title = "Appearance"
        let appearanceItem = NSTabViewItem(viewController: appearance)
        appearanceItem.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)

        let markdown = MarkdownPane()
        markdown.title = "Markdown"
        let markdownItem = NSTabViewItem(viewController: markdown)
        markdownItem.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)

        let advanced = AdvancedPane()
        advanced.title = "Advanced"
        let advancedItem = NSTabViewItem(viewController: advanced)
        advancedItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)

        tabVC.addTabViewItem(generalItem)
        tabVC.addTabViewItem(appearanceItem)
        tabVC.addTabViewItem(markdownItem)
        tabVC.addTabViewItem(advancedItem)
        tabVC.selectedTabViewItemIndex = 1

        let window = NSWindow(contentViewController: tabVC)
        window.styleMask = [.titled, .closable]
        window.title = "Appearance"
        window.setFrameAutosaveName("FolioSettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Base pane helpers

private class SettingsPane: NSViewController {
    let grid = NSGridView()

    override func loadView() {
        view = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            view.widthAnchor.constraint(equalToConstant: 620),
        ])
    }

    func label(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = NSFont.systemFont(ofSize: 13)
        tf.alignment = .right
        return tf
    }

    func addRow(_ title: String, _ control: NSView) {
        grid.addRow(with: [label(title), control])
    }

    func addSwitchRow(_ title: String, _ subtitle: String, isOn: Bool, action: @escaping (Bool) -> Void) {
        let sw = NSSwitch()
        sw.state = isOn ? .on : .off
        let handler = SwitchHandler(action: action)
        sw.target = handler
        sw.action = #selector(SwitchHandler.changed(_:))
        switchHandlers.append(handler)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = NSFont.systemFont(ofSize: 11)
        subLabel.textColor = Ink.tertiary
        let text = NSStackView(views: [titleLabel, subLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [text, NSView(), sw])
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 380).isActive = true
        grid.addRow(with: [NSView(), row])
    }

    private var switchHandlers: [SwitchHandler] = []
}

private final class SwitchHandler: NSObject {
    let action: (Bool) -> Void
    init(action: @escaping (Bool) -> Void) { self.action = action }
    @objc func changed(_ sender: NSSwitch) { action(sender.state == .on) }
}

// MARK: - Panes

private final class GeneralPane: SettingsPane {
    override func loadView() {
        super.loadView()
        let note = NSTextField(wrappingLabelWithString:
            "Folio shows one document per window. Open a file with ⌘O, or a new window with ⌘N.")
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = Ink.secondary
        note.preferredMaxLayoutWidth = 380
        grid.addRow(with: [NSView(), note])
    }
}

private final class AppearancePane: SettingsPane {
    private let sizeValue = NSTextField(labelWithString: "\(AppSettings.defaultTextSize) pt")

    override func loadView() {
        super.loadView()
        let s = AppSettings.shared

        // Reading font
        let font = NSPopUpButton()
        font.addItems(withTitles: AppSettings.ReadingFont.allCases.map(\.displayName))
        font.selectItem(at: AppSettings.ReadingFont.allCases.firstIndex(of: s.readingFont) ?? 0)
        font.target = self
        font.action = #selector(fontChanged(_:))
        font.widthAnchor.constraint(equalToConstant: 230).isActive = true
        addRow("Reading font:", font)

        // Text size
        let slider = NSSlider(value: Double(s.textSize),
                              minValue: Double(AppSettings.minTextSize),
                              maxValue: Double(AppSettings.maxTextSize),
                              target: self, action: #selector(sizeChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        sizeValue.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeValue.textColor = Ink.secondary
        sizeValue.stringValue = "\(s.textSize) pt"
        let small = NSTextField(labelWithString: "A")
        small.font = NSFont.systemFont(ofSize: 11)
        small.textColor = Ink.tertiary
        let big = NSTextField(labelWithString: "A")
        big.font = NSFont.systemFont(ofSize: 17)
        big.textColor = Ink.secondary
        let sizeRow = NSStackView(views: [small, slider, big, sizeValue])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 10
        addRow("Text size:", sizeRow)

        // Line width
        let width = NSSegmentedControl(labels: ["Narrow", "Comfortable", "Wide"], trackingMode: .selectOne, target: self, action: #selector(widthChanged(_:)))
        width.selectedSegment = AppSettings.LineWidth.allCases.firstIndex(of: s.lineWidth) ?? 1
        width.widthAnchor.constraint(equalToConstant: 230).isActive = true
        addRow("Line width:", width)

        // Columns. "Auto" takes as many as fit at the measure, however many that is; a number
        // pins it, and is still bounded by what the window can hold at that measure.
        let choices = AppSettings.ColumnLayout.offered
        let columns = NSSegmentedControl(labels: choices.map { $0.isAutomatic ? "Auto" : "\($0.rawValue)" }, trackingMode: .selectOne, target: self, action: #selector(columnsChanged(_:)))
        columns.selectedSegment = choices.firstIndex(of: s.columnLayout) ?? 0
        columns.widthAnchor.constraint(equalToConstant: 230).isActive = true
        addRow("Columns:", columns)

        // Density
        let density = NSSegmentedControl(labels: ["Airy", "Compact"], trackingMode: .selectOne, target: self, action: #selector(densityChanged(_:)))
        density.selectedSegment = AppSettings.Density.allCases.firstIndex(of: s.density) ?? 0
        density.widthAnchor.constraint(equalToConstant: 230).isActive = true
        addRow("Density:", density)

        // Divider
        let box = NSBox()
        box.boxType = .separator
        grid.addRow(with: [NSView(), box])

        addSwitchRow("Render LaTeX equations", "Display math as styled equation cards", isOn: s.renderEquations) { AppSettings.shared.renderEquations = $0 }
        addSwitchRow("Render Mermaid diagrams", "Flowcharts, sequence, state", isOn: s.renderDiagrams) { AppSettings.shared.renderDiagrams = $0 }
        addSwitchRow("Show frontmatter", "YAML metadata card above the title", isOn: s.showFrontmatter) { AppSettings.shared.showFrontmatter = $0 }
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.readingFont = AppSettings.ReadingFont.allCases[sender.indexOfSelectedItem]
    }
    @objc private func sizeChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue.rounded())
        sizeValue.stringValue = "\(v) pt"
        AppSettings.shared.textSize = v
    }
    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        AppSettings.shared.lineWidth = AppSettings.LineWidth.allCases[sender.selectedSegment]
    }
    @objc private func columnsChanged(_ sender: NSSegmentedControl) {
        AppSettings.shared.columnLayout =
            AppSettings.ColumnLayout.offered[sender.selectedSegment]
    }
    @objc private func densityChanged(_ sender: NSSegmentedControl) {
        AppSettings.shared.density = AppSettings.Density.allCases[sender.selectedSegment]
    }
}

private final class MarkdownPane: SettingsPane {
    override func loadView() {
        super.loadView()
        let s = AppSettings.shared
        addSwitchRow("Render LaTeX equations", "```math fences and $$ blocks", isOn: s.renderEquations) { AppSettings.shared.renderEquations = $0 }
        addSwitchRow("Render Mermaid diagrams", "```mermaid fences", isOn: s.renderDiagrams) { AppSettings.shared.renderDiagrams = $0 }
        addSwitchRow("Show frontmatter", "Leading --- YAML block", isOn: s.showFrontmatter) { AppSettings.shared.showFrontmatter = $0 }
        addSwitchRow("Load remote images", "Off by default: a local-file reader should not reach the network unasked",
                     isOn: s.loadRemoteImages) { AppSettings.shared.loadRemoteImages = $0 }
    }
}

private final class AdvancedPane: SettingsPane {

    private let versionLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    override func loadView() {
        super.loadView()

        // Version, then the update controls: the reader who came here to find out what they are
        // running is the same one deciding whether to fetch something newer.
        versionLabel.font = NSFont.systemFont(ofSize: 13)
        versionLabel.stringValue = AppVersion.summary()
        addRow("Version:", versionLabel)

        let check = NSButton(title: "Check Now", target: self, action: #selector(checkNow))
        check.bezelStyle = .rounded
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = Ink.secondary
        let checkRow = NSStackView(views: [check, statusLabel])
        checkRow.orientation = .horizontal
        checkRow.spacing = 10
        addRow("Updates:", checkRow)

        addSwitchRow("Check for updates automatically",
                     "Once a day, over HTTPS from the GitHub releases page",
                     isOn: AppSettings.shared.automaticUpdateChecks == true) {
            AppSettings.shared.automaticUpdateChecks = $0
            if $0 { UpdateController.shared.check(manual: false) }
        }

        let box = NSBox()
        box.boxType = .separator
        grid.addRow(with: [NSView(), box])

        let note = NSTextField(wrappingLabelWithString: "Folio opens files read-only and never writes to your documents. Only preferences and the recents list are stored.")
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = Ink.secondary
        note.preferredMaxLayoutWidth = 380
        grid.addRow(with: [NSView(), note])

        let reset = NSButton(title: "Reset All Settings", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        grid.addRow(with: [NSView(), reset])

        NotificationCenter.default.addObserver(
            self, selector: #selector(updateStateChanged),
            name: .folioUpdateStateChanged, object: nil)
        refreshStatus()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func updateStateChanged() { refreshStatus() }

    private func refreshStatus() {
        switch UpdateController.shared.state {
        case .idle:
            statusLabel.stringValue = Self.lastCheckedSummary()
        case .checking:
            statusLabel.stringValue = "Checking…"
        case .upToDate:
            statusLabel.stringValue = "Up to date."
        case .available(let release):
            statusLabel.stringValue = "Folio \(release.version) is available."
        case .downloading(_, let fraction):
            statusLabel.stringValue = "Downloading… \(Int((fraction * 100).rounded()))%"
        case .readyToInstall(let release, _):
            statusLabel.stringValue = "Folio \(release.version) is ready to install."
        case .installing:
            statusLabel.stringValue = "Installing…"
        case .failed(let error):
            statusLabel.stringValue = error.message
        }
    }

    private static func lastCheckedSummary() -> String {
        guard let last = AppSettings.shared.lastUpdateCheck else { return "Not checked yet." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: last, relativeTo: Date()))."
    }

    @objc private func checkNow() {
        UpdateController.shared.check(manual: true)
    }

    @objc private func resetAll() {
        let domain = Bundle.main.bundleIdentifier ?? "io.huylg.folio"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        AppSettings.shared.applyTheme()
        NotificationCenter.default.post(name: .folioSettingsChanged, object: nil)
    }
}
