import AppKit

/// The welcome screen: the whole window until a document is open.
///
/// A screen of its own rather than a panel inside the reading pane. As an overlay it shared the
/// window with an outline sidebar that had nothing to list, and opening a document only swapped
/// one hidden view for another — the sidebar and the toolbar stayed exactly as they were, so
/// nothing about the window said the reader had arrived anywhere. Opening a document from here
/// navigates to the reading screen instead: see `MainWindowController.showDocumentScreen()`.
public final class WelcomeViewController: NSViewController {

    public var onOpenDocument: (() -> Void)?
    public var onOpenRecent: ((URL) -> Void)?

    private let recentsStack = NSStackView()
    private let recentsHeader = NSTextField(labelWithString: "RECENT")

    public override func loadView() {
        view = NSView()
        view.wantsLayer = true
        build()
    }

    private func build() {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Document")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 56, weight: .ultraLight)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "No document open")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let openButton = NSButton(title: "Open document…", target: self, action: #selector(openDoc))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [openButton])
        buttons.orientation = .horizontal

        let divider = NSBox()
        divider.boxType = .separator

        recentsHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        recentsHeader.textColor = Ink.tertiary

        recentsStack.orientation = .vertical
        recentsStack.alignment = .leading
        recentsStack.spacing = 2

        let column = NSStackView(views: [icon, title, buttons, divider, recentsHeader, recentsStack])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.setCustomSpacing(20, after: icon)
        column.setCustomSpacing(24, after: title)
        column.setCustomSpacing(28, after: buttons)
        column.setCustomSpacing(14, after: divider)
        column.setCustomSpacing(8, after: recentsHeader)
        column.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            column.widthAnchor.constraint(equalToConstant: 440),
            divider.widthAnchor.constraint(equalTo: column.widthAnchor),
            recentsStack.widthAnchor.constraint(equalTo: column.widthAnchor),
            recentsHeader.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 4),
        ])

        reloadRecents()
    }

    public func reloadRecents() {
        guard isViewLoaded else { return }
        recentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let recents = AppSettings.shared.recents
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(3)
        recentsHeader.isHidden = recents.isEmpty

        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated

        for recent in recents {
            let url = URL(fileURLWithPath: recent.path)
            let row = RecentRow(url: url, when: fmt.localizedString(for: recent.date, relativeTo: Date()))
            row.onClick = { [weak self] in self?.onOpenRecent?(url) }
            recentsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentsStack.widthAnchor).isActive = true
        }
    }

    /// The recents rows, in the order they are shown, for a test that stands in for the hand: a
    /// row is clicked through a gesture recognizer, which a synthesized event does not reach.
    var recentRows: [RecentRow] { recentsStack.arrangedSubviews.compactMap { $0 as? RecentRow } }

    @objc private func openDoc() { onOpenDocument?() }
}

final class RecentRow: NSView {
    var onClick: (() -> Void)?

    init(url: URL, when: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
        icon.contentTintColor = Ink.tertiary
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = NSFont.systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let date = NSTextField(labelWithString: when)
        date.font = NSFont.systemFont(ofSize: 11)
        date.textColor = Ink.tertiary

        let stack = NSStackView(views: [icon, name, NSView(), date])
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
    }

    required public init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.cornerRadius = 6
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = .clear
    }

    @objc private func clicked() { onClick?() }
}
