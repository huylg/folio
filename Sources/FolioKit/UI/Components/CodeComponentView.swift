import AppKit

/// A fenced code block: a headered card with a copy button and selectable, highlighted source.
/// A block fenced as a shell language (`bash`, `sh`, `shell`, `zsh`) also gets a Run button
/// that executes the source at the document's project root. Every run gets a console of its
/// own under the code — newest on top, each with its own timestamp and close button — so one
/// result can be dismissed without losing the others.
///
/// A run's state lives in a `RunSession`, not in this view: the card renders the sessions of
/// its block's key out of a `RunSessionStore`, and any other card bound to the same key — the
/// same block shown in a peek card, say — shows the same consoles, live. An unbound card owns
/// a private store, which is the same machinery with one subscriber.
///
/// The card used to be painted *behind* the text by a chain of custom layout fragments, one per
/// line, each reconstructing its slice of the card's fill, border, and corners out of paragraph
/// spacing — because the text lived in the document-wide text view and a view could not own that
/// geometry. As a component it is simply a card with a text view in it: the chrome is drawn
/// once, the corners are one rounded rect, and the padding is layout rather than an attribute
/// smuggled through the paragraph style.
public final class CodeComponentView: HeaderedCardView {

    public let source: String
    public weak var host: BlockHost?

    private let body = TextComponentView()
    private var copyButton: NSButton?
    private var copyResetTimer: Timer?
    private(set) var runButton: NSButton?

    /// The block's identity in the session store, and the store itself. Bound by the document
    /// stack when the block belongs to a document with a shared store; private and synthetic
    /// otherwise, so both cases run the same code.
    private(set) var runKey: RunBlockKey
    private(set) var sessionStore: RunSessionStore
    private var storeToken: UUID?

    /// One console per session, newest first. Re-running stacks a new console on top; each
    /// closes on its own. The card view is retained across scrolling, and the sessions outlive
    /// even the view — a card recreated over the same store adopts them back.
    private(set) var runPanels: [RunOutputPanel] = []
    /// The finished-run history, newest first. Consoles still running have no entry yet.
    var runEntries: [RunSession.Entry] { runPanels.compactMap(\.entry) }
    /// The most recent finished result — nil while no console has finished.
    var runOutput: ProcessRunner.Output? { runPanels.compactMap(\.entry).first?.output }

    /// Breathing room between the code card and the first console, and between consoles —
    /// they are separate cards, not extensions of the code card.
    static let consoleGap: CGFloat = 8

    public override var cardFillColor: NSColor { Ink.codeBackground }

    public init(label: String, source: String, language: String? = nil,
                lines: NSAttributedString, metrics: DocumentMetrics, host: BlockHost?) {
        self.source = source
        self.host = host
        self.sessionStore = RunSessionStore()
        self.runKey = RunBlockKey(documentURL: URL(fileURLWithPath: "/"), location: 0)
        super.init(metrics: metrics, label: label)

        if ProcessRunner.isShellLanguage(language) {
            runButton = addHeaderButton(symbol: "play", label: "Run",
                                        target: self, action: #selector(runSource))
        }
        copyButton = addHeaderButton(symbol: "doc.on.doc", label: "Copy",
                                     target: self, action: #selector(copySource))

        body.configure(with: Self.codeText(lines), kind: .codeLine(isFirst: true, isLast: true))
        body.translatesAutoresizingMaskIntoConstraints = true
        addSubview(body)

        setAccessibilityRole(.group)
        setAccessibilityLabel("\(label) code")

        storeToken = sessionStore.addObserver { [weak self] key in
            self?.storeChanged(key)
        }
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        copyResetTimer?.invalidate()
        if let storeToken { sessionStore.removeObserver(storeToken) }
    }

    /// Points the card at its block's shared history. Called by the document stack right after
    /// construction; existing sessions are adopted — their consoles appear already settled, no
    /// unfold — and the host is told once so the page makes room for them.
    func bindRunSessions(key: RunBlockKey, store: RunSessionStore) {
        if let storeToken { sessionStore.removeObserver(storeToken) }
        for panel in runPanels { panel.removeFromSuperview() }
        runPanels = []

        runKey = key
        sessionStore = store
        storeToken = store.addObserver { [weak self] key in
            self?.storeChanged(key)
        }

        let existing = store.sessions(for: key)
        guard !existing.isEmpty else { return }
        for session in existing {
            let panel = makePanel(for: session)
            runPanels.append(panel)
            addSubview(panel)
            panel.revealInstantly()
        }
        setAccessibilityLabel(accessibilityBaseLabel + ", with command output")
        needsLayout = true
        host?.blockHeightDidChange(self)
    }

    /// The store changed shape under this block's key: a session began somewhere — here, or in
    /// another card bound to the same block. Consoles it lost fold away through their own
    /// `.closed` events; only arrivals are handled here, and they unfold, because this view is
    /// witnessing the run begin.
    private func storeChanged(_ key: RunBlockKey) {
        guard key == runKey else { return }
        let sessions = sessionStore.sessions(for: runKey)
        for session in sessions
        where !runPanels.contains(where: { $0.session === session }) {
            let panel = makePanel(for: session)
            runPanels.insert(panel, at: 0)
            addSubview(panel)
            setAccessibilityLabel(accessibilityBaseLabel + ", with command output")
            panel.unfold()
        }
    }

    private func makePanel(for session: RunSession) -> RunOutputPanel {
        let panel = RunOutputPanel(session: session, metrics: metrics)
        panel.onHeightChange = { [weak self] in
            guard let self else { return }
            needsLayout = true
            host?.blockHeightDidChange(self)
        }
        panel.onClose = { [weak self] panel in
            guard let self else { return }
            runPanels.removeAll { $0 === panel }
            panel.removeFromSuperview()
            if runPanels.isEmpty { setAccessibilityLabel(accessibilityBaseLabel) }
        }
        return panel
    }

    /// Strips the paragraph spacing from the code lines.
    ///
    /// The card owns its own padding now. The spacing on the first and last line existed so the
    /// old layout fragments had something to paint the header strip and the bottom padding out
    /// of; left in place it would be added to the card's padding and the block would grow a dead
    /// band at each end. The indents are kept — they are what makes a wrapped line hang past its
    /// own indentation.
    static func codeText(_ lines: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: lines)
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy()
                    as? NSMutableParagraphStyle else { return }
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return out
    }

    /// The code text's height at the last width asked for. The code never changes after init,
    /// so the measure is pure in the width — and it is read from `layout()` and `cardRect`
    /// (which runs on every draw) once consoles exist, where re-running TextKit per scroll
    /// frame is what made pages with consoles crawl.
    private var cachedCodeTextHeight: (width: CGFloat, height: CGFloat)?

    private func codeTextHeight(width: CGFloat) -> CGFloat {
        if let cached = cachedCodeTextHeight, cached.width == width { return cached.height }
        let height = TextComponentView.height(of: body.attributedString(), width: width)
        cachedCodeTextHeight = (width, height)
        return height
    }

    public override func layout() {
        super.layout()
        let insets = metrics.codeCardInsets
        // With consoles below, the code's height comes from its own text rather than from
        // what remains of the card.
        let codeHeight = runPanels.isEmpty
            ? bounds.height - CardChrome.headerHeight - insets.bodyTop - insets.bodyBottom
            : codeTextHeight(width: max(1, bounds.width))
        body.frame = NSRect(
            x: 0,
            y: CardChrome.headerHeight + insets.bodyTop,
            width: max(1, bounds.width),
            height: max(1, codeHeight)
        )

        // The consoles are separate cards stacked below the code card, newest first, each
        // preceded by a gap. Gap and card height both scale with the panel's reveal, so a
        // console mid-unfold pushes everything below it down smoothly.
        var top = body.frame.maxY + insets.bodyBottom
        for panel in runPanels {
            top += (Self.consoleGap * panel.reveal).rounded()
            let height = panel.revealedHeight(width: bounds.width)
            panel.frame = NSRect(x: 0, y: top, width: max(1, bounds.width), height: height)
            top += height
        }
    }

    /// The code card's chrome ends at the code; the consoles below draw their own cards.
    public override var cardRect: NSRect {
        guard !runPanels.isEmpty else { return bounds }
        let insets = metrics.codeCardInsets
        return NSRect(x: 0, y: 0, width: bounds.width,
                      height: CardChrome.headerHeight + insets.bodyTop
                          + codeTextHeight(width: max(1, bounds.width)) + insets.bodyBottom)
    }

    /// The click itself is the consent: the source is right there in the card. The button is
    /// never blocked — a run's whole lifecycle lives in its console, which appears immediately
    /// as a live pty view, and another click simply opens another console.
    ///
    /// The run writes into its session, never into a view: the console — every console bound
    /// to the session, on whatever surface — follows along by observing it, and a view that
    /// dies mid-run cannot strand the result.
    @objc private func runSource() {
        guard let host else { return }
        let session = sessionStore.begin(key: runKey)
        host.blockRequestsRun(
            source,
            onOutput: { session.appendOutput($0) },
            completion: { session.finish(with: $0) }
        )
    }

    // MARK: Run consoles

    /// Opens a console in its running state — spinner up, stamped with the start time — and
    /// unfolds it. The caller finishes it with the result when the command exits. The store's
    /// observers run synchronously, so the panel exists by the time `begin` returns.
    @discardableResult
    func beginRunConsole() -> RunOutputPanel {
        sessionStore.begin(key: runKey)
        return runPanels[0]
    }

    /// A console that arrives already finished — the test seam, and the shape `runSource`
    /// produces once its command exits.
    func showRunOutput(_ result: ProcessRunner.Output) {
        sessionStore.begin(key: runKey).finish(with: result)
    }

    private var accessibilityBaseLabel: String {
        "\(headerLabel.stringValue) code"
    }

    /// What the consoles add to the component's height at `width` — each panel's gap and
    /// revealed card, so a console mid-unfold contributes exactly what it shows.
    /// `DocumentStackView` adds this to the static code height when it measures the component,
    /// which is what makes an unfold or a close move the page.
    func outputPanelHeight(width: CGFloat) -> CGFloat {
        runPanels.reduce(0) {
            $0 + (Self.consoleGap * $1.reveal).rounded() + $1.revealedHeight(width: width)
        }
    }

    @objc private func copySource() {
        host?.blockRequestsCopy(source)
        copyButton?.image = NSImage(systemSymbolName: "checkmark",
                                    accessibilityDescription: "Copied")
        copyButton?.contentTintColor = Ink.accent
        copyResetTimer?.invalidate()
        // Transient, and lost if the card scrolls out and its view is recycled. Not worth
        // plumbing through the document.
        copyResetTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.copyButton?.image = NSImage(systemSymbolName: "doc.on.doc",
                                              accessibilityDescription: "Copy")
            self?.copyButton?.contentTintColor = Ink.tertiary
        }
    }

    public static func height(lines: NSAttributedString, width: CGFloat,
                              metrics: DocumentMetrics) -> CGFloat {
        let insets = metrics.codeCardInsets
        let text = TextComponentView.height(of: codeText(lines), width: max(1, width))
        return CardChrome.headerHeight + insets.bodyTop + text + insets.bodyBottom
    }

    public override func sizeThatFits(width: CGFloat) -> CGSize {
        let insets = metrics.codeCardInsets
        return CGSize(width: width,
                      height: CardChrome.headerHeight + insets.bodyTop
                          + codeTextHeight(width: max(1, width)) + insets.bodyBottom
                          + outputPanelHeight(width: width))
    }
}

/// A thematic break.
public final class RuleComponentView: NSView, DimmableComponent {

    public var isDimmed: Bool = false {
        didSet {
            guard isDimmed != oldValue else { return }
            alphaValue = isDimmed ? 0.34 : 1.0
        }
    }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        Ink.hairline.setFill()
        NSRect(x: 0, y: (bounds.height / 2).rounded(), width: bounds.width, height: 1).fill()
    }
}
