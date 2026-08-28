import AppKit

/// A fenced code block: a headered card with a copy button and selectable, highlighted source.
/// A block fenced as a shell language (`bash`, `sh`, `shell`, `zsh`) also gets a Run button
/// that executes the source at the document's project root. The block keeps **one** console
/// under the code — stamped with the run's time, with its own close button — and re-running
/// replaces it rather than stacking a second one.
///
/// The Run button is out while any block in the document is running: runs are serial, so a
/// reader working through a page of commands runs them one at a time instead of racing two
/// of them at the same project root.
///
/// A run's state lives in a `RunSession`, not in this view: the card renders the session of
/// its block's key out of a `RunSessionStore`, and any other card bound to the same key — the
/// same block shown in a peek card, say — shows the same console, live. An unbound card owns
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

    /// The block's console, or nil when it has none. The card view is retained across
    /// scrolling, and the session outlives even the view — a card recreated over the same
    /// store adopts its console back.
    private(set) var runPanel: RunOutputPanel?
    /// The finished run — nil while the console is still running, or has none.
    var runEntry: RunSession.Entry? { runPanel?.entry }
    /// The finished result — nil while the console has not finished.
    var runOutput: ProcessRunner.Output? { runPanel?.entry?.output }

    /// Breathing room between the code card and the console — a separate card, not an
    /// extension of the code card.
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

    /// Points the card at its block's shared console. Called by the document stack right after
    /// construction; an existing session is adopted — its console appears already settled, no
    /// unfold — and the host is told once so the page makes room for it.
    func bindRunSessions(key: RunBlockKey, store: RunSessionStore) {
        if let storeToken { sessionStore.removeObserver(storeToken) }
        runPanel?.detach()
        runPanel = nil

        runKey = key
        sessionStore = store
        storeToken = store.addObserver { [weak self] key in
            self?.storeChanged(key)
        }
        syncRunButton()

        guard let session = store.session(for: key) else { return }
        let panel = makePanel(for: session)
        runPanel = panel
        addSubview(panel)
        panel.revealInstantly()
        setAccessibilityLabel(accessibilityBaseLabel + ", with command output")
        needsLayout = true
        host?.blockHeightDidChange(self)
    }

    /// A session began, finished, or closed somewhere in the document — here, or in another
    /// card bound to the same store. The console follows this block's own key; the Run button
    /// follows every key, since one running block is what puts all of them out.
    private func storeChanged(_ key: RunBlockKey) {
        if key == runKey { syncConsole() }
        syncRunButton()
    }

    /// Brings the console into line with the block's session. A console the store no longer
    /// has folds away through its own `.closed` event, so only arrivals are handled here: the
    /// first one unfolds, because this view is witnessing the run begin, while one replacing a
    /// previous run takes its slot outright — the console resets rather than collapsing and
    /// growing back.
    private func syncConsole() {
        guard let session = sessionStore.session(for: runKey),
              runPanel?.session !== session else { return }
        let replaced = runPanel
        replaced?.detach()

        let panel = makePanel(for: session)
        runPanel = panel
        addSubview(panel)
        setAccessibilityLabel(accessibilityBaseLabel + ", with command output")
        guard replaced != nil else { return panel.unfold() }
        panel.revealInstantly()
        needsLayout = true
        host?.blockHeightDidChange(self)
    }

    /// Runs are serial, so the button is out from the moment any block in the document starts
    /// until it exits — including this one's, which is what makes a second click impossible
    /// rather than merely ignored.
    private func syncRunButton() {
        guard let runButton else { return }
        let busy = sessionStore.isRunning
        runButton.isEnabled = !busy
        runButton.contentTintColor = busy ? Ink.decorative : Ink.tertiary
        runButton.toolTip = busy ? "A command is already running" : "Run"
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
            panel.removeFromSuperview()
            guard runPanel === panel else { return }
            runPanel = nil
            setAccessibilityLabel(accessibilityBaseLabel)
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
        // With a console below, the code's height comes from its own text rather than from
        // what remains of the card.
        let codeHeight = runPanel == nil
            ? bounds.height - CardChrome.headerHeight - insets.bodyTop - insets.bodyBottom
            : codeTextHeight(width: max(1, bounds.width))
        body.frame = NSRect(
            x: 0,
            y: CardChrome.headerHeight + insets.bodyTop,
            width: max(1, bounds.width),
            height: max(1, codeHeight)
        )

        // The console is a separate card below the code card, preceded by a gap. Gap and card
        // height both scale with the panel's reveal, so a console mid-unfold pushes everything
        // below it down smoothly. Once it has unfolded neither number moves again.
        guard let panel = runPanel else { return }
        let top = body.frame.maxY + insets.bodyBottom
            + (Self.consoleGap * panel.reveal).rounded()
        panel.frame = NSRect(x: 0, y: top, width: max(1, bounds.width),
                             height: panel.revealedHeight)
    }

    /// The code card's chrome ends at the code; the console below draws its own card.
    public override var cardRect: NSRect {
        guard runPanel != nil else { return bounds }
        let insets = metrics.codeCardInsets
        return NSRect(x: 0, y: 0, width: bounds.width,
                      height: CardChrome.headerHeight + insets.bodyTop
                          + codeTextHeight(width: max(1, bounds.width)) + insets.bodyBottom)
    }

    /// The click itself is the consent: the source is right there in the card. A run's whole
    /// lifecycle lives in its console, which appears immediately as a live pty view and
    /// replaces whatever the block showed before.
    ///
    /// The store refuses while another run is in flight — the button is already out by then,
    /// so this only catches a click that raced the disable.
    ///
    /// The run writes into its session, never into a view: the console — every console bound
    /// to the session, on whatever surface — follows along by observing it, and a view that
    /// dies mid-run cannot strand the result.
    @objc private func runSource() {
        guard let host, let session = sessionStore.begin(key: runKey) else { return }
        host.blockRequestsRun(
            source,
            onOutput: { session.appendOutput($0) },
            completion: { session.finish(with: $0) }
        )
    }

    // MARK: The run console

    /// A console that arrives already finished — the test seam, and the shape `runSource`
    /// produces once its command exits.
    func showRunOutput(_ result: ProcessRunner.Output) {
        sessionStore.begin(key: runKey)?.finish(with: result)
    }

    private var accessibilityBaseLabel: String {
        "\(headerLabel.stringValue) code"
    }

    /// What the console adds to the component's height — its gap and revealed card, so a
    /// console mid-unfold contributes exactly what it shows. `DocumentStackView` adds this to
    /// the static code height when it measures the component, which is what makes an unfold or
    /// a close move the page. Nothing else does: a settled console reports the same number for
    /// the rest of its life, whatever the command goes on to print.
    var outputPanelHeight: CGFloat {
        guard let panel = runPanel else { return 0 }
        return (Self.consoleGap * panel.reveal).rounded() + panel.revealedHeight
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
                          + outputPanelHeight)
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
