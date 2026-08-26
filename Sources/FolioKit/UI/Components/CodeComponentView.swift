import AppKit

/// A fenced code block: a headered card with a copy button and selectable, highlighted source.
/// A block fenced as a shell language (`bash`, `sh`, `shell`, `zsh`) also gets a Run button
/// that executes the source at the document's project root. Every run gets a console of its
/// own under the code — newest on top, each with its own timestamp and close button — so one
/// result can be dismissed without losing the others.
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

    /// One finished run, timestamped so an older entry's divider can say when it was.
    struct RunEntry {
        let output: ProcessRunner.Output
        let finishedAt: Date
    }

    /// One console per run, newest first. Re-running stacks a new console on top; each closes
    /// on its own. The card view is retained across scrolling, which is what lets the consoles
    /// survive the reader leaving and coming back.
    private(set) var runPanels: [RunOutputPanel] = []
    /// The finished-run history, newest first. Consoles still running have no entry yet.
    var runEntries: [RunEntry] { runPanels.compactMap(\.entry) }
    /// The most recent finished result — nil while no console has finished.
    var runOutput: ProcessRunner.Output? { runPanels.compactMap(\.entry).first?.output }

    /// A console's text scrolls internally past this, so one chatty command cannot turn the
    /// page into its log.
    static let maxOutputTextHeight: CGFloat = 220
    /// Older consoles beyond this fall off the bottom of the history.
    static let maxRunHistory = 10
    /// Breathing room between the code card and the first console, and between consoles —
    /// they are separate cards, not extensions of the code card.
    static let consoleGap: CGFloat = 8
    /// How long a console takes to unfold or fold away. A `static var` so tests can zero it
    /// and assert on final geometry.
    static var outputRevealDuration: TimeInterval = 0.22

    public override var cardFillColor: NSColor { Ink.codeBackground }

    public init(label: String, source: String, language: String? = nil,
                lines: NSAttributedString, metrics: DocumentMetrics, host: BlockHost?) {
        self.source = source
        self.host = host
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
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    deinit { copyResetTimer?.invalidate() }

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

    public override func layout() {
        super.layout()
        let insets = metrics.codeCardInsets
        // With consoles below, the code's height comes from its own text rather than from
        // what remains of the card.
        let codeHeight = runPanels.isEmpty
            ? bounds.height - CardChrome.headerHeight - insets.bodyTop - insets.bodyBottom
            : TextComponentView.height(of: body.attributedString(), width: max(1, bounds.width))
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
        return NSRect(x: 0, y: 0, width: bounds.width,
                      height: Self.height(lines: body.attributedString(),
                                          width: max(1, bounds.width), metrics: metrics))
    }

    /// The click itself is the consent: the source is right there in the card. The button is
    /// never blocked — a run's whole lifecycle lives in its console, which appears immediately
    /// as a live pty view, and another click simply opens another console.
    @objc private func runSource() {
        guard let host else { return }
        let panel = beginRunConsole()
        host.blockRequestsRun(
            source,
            onOutput: { [weak self, weak panel] transcript in
                guard let self, let panel,
                      runPanels.contains(where: { $0 === panel }) else { return }
                panel.showLiveOutput(transcript)
            },
            completion: { [weak self, weak panel] result in
                guard let self, let panel,
                      runPanels.contains(where: { $0 === panel }) else { return }
                if let result {
                    panel.finish(with: result)
                } else {
                    // Nothing ran — the host had no document. The empty console folds away.
                    panel.foldAway()
                }
            }
        )
    }

    // MARK: Run consoles

    /// Opens a console in its running state — spinner up, stamped with the start time — and
    /// unfolds it. The caller finishes it with the result when the command exits.
    @discardableResult
    func beginRunConsole() -> RunOutputPanel {
        let panel = RunOutputPanel(startedAt: Date(), metrics: metrics)
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
        runPanels.insert(panel, at: 0)
        addSubview(panel)
        if runPanels.count > Self.maxRunHistory {
            for dropped in runPanels[Self.maxRunHistory...] { dropped.removeFromSuperview() }
            runPanels.removeLast(runPanels.count - Self.maxRunHistory)
        }
        setAccessibilityLabel(accessibilityBaseLabel + ", with command output")
        panel.unfold()
        return panel
    }

    /// A console that arrives already finished — the test seam, and the shape `runSource`
    /// produces once its command exits.
    func showRunOutput(_ result: ProcessRunner.Output) {
        beginRunConsole().finish(with: result)
    }

    private var accessibilityBaseLabel: String {
        "\(headerLabel.stringValue) code"
    }

    /// The result as attributed text: stdout in body ink, stderr and a non-zero exit in red,
    /// and an explicit "(no output)" so a silent success never looks like a dead button.
    /// Static so the height measure and the rendered panel read the same string.
    static func outputText(_ result: ProcessRunner.Output,
                           metrics: DocumentMetrics) -> NSAttributedString {
        let font = TypeRamp.fixedPitchMono(ofSize: metrics.ramp.caption().pointSize)
        let out = NSMutableAttributedString()
        func line(_ text: String, _ color: NSColor) {
            if out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            out.append(NSAttributedString(string: text,
                                          attributes: [.font: font, .foregroundColor: color]))
        }
        if result.status != 0 { line("exit \(result.status)", .systemRed) }
        if !result.outputText.isEmpty { line(result.outputText, Ink.body) }
        if !result.errorText.isEmpty { line(result.errorText, .systemRed) }
        if out.length == 0 { line("(no output)", Ink.tertiary) }
        return out
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
        CGSize(width: width,
               height: Self.height(lines: body.attributedString(), width: width,
                                   metrics: metrics)
                   + outputPanelHeight(width: width))
    }
}

/// One run's console: a card of its own below the code card — the same headered-card chrome,
/// with the run's finish time as the label, its own close button, and the result text,
/// scrollable past the cap. Each console unfolds on arrival and folds away when closed,
/// independently of its siblings.
///
/// Layer-masked, unlike other cards: its height animates, and an NSView does not clip its
/// subviews on its own — a half-revealed console would otherwise draw over whatever sits
/// below it. The card chrome is still painted in `draw(_:)`, so it grows with the reveal and
/// dynamic colors keep resolving at draw time.
final class RunOutputPanel: HeaderedCardView {

    /// The finished run — nil while the command is still running. The header is stamped with
    /// the start time, so the console carries the run from launch to exit.
    private(set) var entry: CodeComponentView.RunEntry?
    var isRunning: Bool { entry == nil }

    /// Re-measure hook: the owning card forwards this to its host on every animation step.
    var onHeightChange: (() -> Void)?
    /// Fired after the fold-away finishes; the owning card removes the panel.
    var onClose: ((RunOutputPanel) -> Void)?

    /// How far the console has unfolded, 0…1. Height and alpha both follow it.
    private(set) var reveal: CGFloat = 0
    private var revealTimer: Timer?

    private(set) var closeButton: NSButton!
    private let scroll = ConsoleScrollView()
    private let textView = TextComponentView()
    private let spinner = NSProgressIndicator()

    /// What the pty has produced so far — the live body until the command exits.
    private(set) var liveTranscript = ""

    /// The body never collapses below one row, so a console that has printed nothing yet is
    /// still visibly a console.
    static let minimumBodyHeight: CGFloat = 16

    override var cardFillColor: NSColor { Ink.codeBackground }

    init(startedAt: Date, metrics: DocumentMetrics) {
        super.init(metrics: metrics, label: Self.timeFormatter.string(from: startedAt))
        wantsLayer = true
        layer?.masksToBounds = true
        alphaValue = 0

        // Activity lives in the header — the body belongs to the pty from the first byte.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        headerAccessories.addArrangedSubview(spinner)

        closeButton = addHeaderButton(symbol: "xmark", label: "Close result",
                                      target: self, action: #selector(closeTapped))

        // The text lives in a scroll view so output taller than the cap scrolls in place
        // instead of growing the page. Lines are never wrapped — a long line scrolls
        // sideways, the way it would in a terminal — so the container must not track the
        // view's width.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        addSubview(scroll)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Command running since \(headerLabel.stringValue)")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { revealTimer?.invalidate() }

    /// A fresh slice of the pty stream: the full transcript so far, shown live. The console
    /// grows with it (up to the cap) and keeps the tail in view, the way a terminal does —
    /// unless the reader has scrolled back to read, in which case their place is theirs.
    func showLiveOutput(_ transcript: String) {
        guard isRunning else { return }
        // Decided before the text changes: "was the reader at the tail" only means anything
        // against the old content.
        pinTailAfterLayout = isScrolledToTail
        liveTranscript = transcript
        textView.configure(with: Self.liveText(transcript, metrics: metrics), kind: .paragraph)
        needsLayout = true
        onHeightChange?()
    }

    /// Whether the viewport is at (or within a line of) the end of the transcript. A console
    /// not yet laid out, or one whose transcript still fits the viewport, counts as at the
    /// tail — there is no reading place to preserve yet.
    private var isScrolledToTail: Bool {
        let clip = scroll.contentView.bounds
        guard clip.height > 0, textView.frame.height > clip.height else { return true }
        return clip.maxY >= textView.frame.height - outputLineHeight
    }

    /// One line of console output, measured once — the unit the viewport is sized in.
    private lazy var outputLineHeight: CGFloat = max(
        1, TextComponentView.height(of: Self.liveText("x", metrics: metrics), width: 1000)
    )

    /// Set when a live update arrives with the reader at the tail; consumed by `layout()`,
    /// because the scroll must happen *after* the text view has grown to hold the new tail —
    /// scrolling first is how the last line ends up half-clipped below the viewport.
    private var pinTailAfterLayout = false

    /// The command exited: the live view settles into the logged result — same body, plus the
    /// exit line when it failed. The console eases from its live height to the result's height
    /// by re-entering the reveal from the ratio of the two, so the change is animated rather
    /// than a jump.
    func finish(with output: ProcessRunner.Output) {
        let width = max(1, bounds.width)
        let runningHeight = fullHeight(width: width)

        entry = CodeComponentView.RunEntry(output: output, finishedAt: Date())
        spinner.stopAnimation(nil)
        spinner.removeFromSuperview()
        textView.configure(with: CodeComponentView.outputText(output, metrics: metrics),
                           kind: .paragraph)
        setAccessibilityLabel("Command output from \(headerLabel.stringValue)")

        let finishedHeight = fullHeight(width: width)
        if reveal >= 1, finishedHeight > 0, runningHeight != finishedHeight,
           CodeComponentView.outputRevealDuration > 0 {
            reveal = runningHeight / finishedHeight
            animateReveal(to: 1)
        } else {
            // Mid-unfold (or animations off): the running reveal continues into the new
            // height on its own — revealed height is always a fraction of the current full.
            needsLayout = true
            onHeightChange?()
        }
    }

    /// The current body text: the logged result once finished, the raw pty transcript before.
    private var bodyText: NSAttributedString {
        if let entry { return CodeComponentView.outputText(entry.output, metrics: metrics) }
        return Self.liveText(liveTranscript, metrics: metrics)
    }

    /// Live pty text, before any exit dressing — plain body ink, same mono face as the log.
    static func liveText(_ transcript: String, metrics: DocumentMetrics) -> NSAttributedString {
        NSAttributedString(string: transcript, attributes: [
            .font: TypeRamp.fixedPitchMono(ofSize: metrics.ramp.caption().pointSize),
            .foregroundColor: Ink.body,
        ])
    }

    /// Console lines never wrap, so heights are measured at effectively infinite width — a
    /// long line costs sideways scrolling, never extra rows.
    static let unwrappedMeasureWidth: CGFloat = 1_000_000

    func fullHeight(width: CGFloat) -> CGFloat {
        let insets = metrics.codeCardInsets
        let content = TextMeasurer.shared.size(of: bodyText,
                                               width: Self.unwrappedMeasureWidth)
        return CardChrome.headerHeight + insets.bodyTop
            + scrollViewportHeight(forContent: content, panelWidth: width)
            + insets.bodyBottom
    }

    /// The scroll view's height at `width`: the whole-line text area, plus the horizontal
    /// bar's thickness when the widest line overflows sideways. Legacy bars are carved out of
    /// the viewport, so a viewport sized to exactly the text would lose its last line to the
    /// bar. Deterministic, because the console pins its scroller style.
    private func scrollViewportHeight(forContent content: NSSize,
                                      panelWidth width: CGFloat) -> CGFloat {
        let body = cappedBodyHeight(for: content.height)
        let thickness = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            .rounded(.up)
        // A vertical bar narrows the text area, which can itself push a line into overflow.
        let textArea = Self.textWidth(panelWidth: width, metrics: metrics)
            - (content.height > body ? thickness : 0)
        return body + (content.width > textArea ? thickness : 0)
    }

    /// The text area's height for a body of `textHeight`: capped, and the cap rounded down to
    /// whole lines — a viewport that is 13½ lines tall shows half a string at its edge no
    /// matter how correctly it is scrolled.
    private func cappedBodyHeight(for textHeight: CGFloat) -> CGFloat {
        guard textHeight > CodeComponentView.maxOutputTextHeight else {
            return max(Self.minimumBodyHeight, textHeight)
        }
        let whole = (CodeComponentView.maxOutputTextHeight / outputLineHeight)
            .rounded(.down) * outputLineHeight
        return max(Self.minimumBodyHeight, whole)
    }

    func revealedHeight(width: CGFloat) -> CGFloat {
        (fullHeight(width: width) * min(max(reveal, 0), 1)).rounded()
    }

    static func textWidth(panelWidth: CGFloat, metrics: DocumentMetrics) -> CGFloat {
        let gutter = (CardChrome.codeGutter * metrics.ramp.scale).rounded()
        return max(1, panelWidth - gutter * 2)
    }

    override func layout() {
        super.layout()
        let insets = metrics.codeCardInsets
        let gutter = (CardChrome.codeGutter * metrics.ramp.scale).rounded()
        let width = max(1, bounds.width)

        let viewportWidth = Self.textWidth(panelWidth: width, metrics: metrics)
        let content = TextMeasurer.shared.size(of: bodyText, width: Self.unwrappedMeasureWidth)
        // The document is as wide as its widest line; a narrower transcript still fills the
        // viewport so selection and clicks behave across its whole width.
        textView.frame = NSRect(x: 0, y: 0,
                                width: max(viewportWidth, content.width),
                                height: max(1, content.height))
        scroll.frame = NSRect(
            x: gutter,
            y: CardChrome.headerHeight + insets.bodyTop,
            width: viewportWidth,
            height: scrollViewportHeight(forContent: content, panelWidth: width)
        )
        if pinTailAfterLayout {
            pinTailAfterLayout = false
            // Directly on the clip view: deterministic, and it must happen after the text
            // view has grown — scrolling first is how the last line ends up half-clipped.
            let tail = NSPoint(x: 0, y: max(0, textView.frame.height
                                                - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: tail)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width, height: fullHeight(width: width))
    }

    func unfold() { animateReveal(to: 1) }

    /// Folds the console away and hands it back to the owner — the close button's path, and
    /// the card's when a run produced nothing to show.
    func foldAway() {
        animateReveal(to: 0) { [weak self] in
            guard let self else { return }
            onClose?(self)
        }
    }

    @objc private func closeTapped() { foldAway() }

    /// The console's scroll view, pinned to legacy scrollers whatever the system prefers:
    /// a console's bars should be visible and grabbable whenever content overflows, not
    /// appear only mid-gesture. Pinning also makes the geometry deterministic — the panel's
    /// measured height reserves the bar's thickness, and that must not change with whichever
    /// input device the machine last saw. AppKit re-applies the preferred style on device
    /// changes, so the setter must hold the line rather than the init.
    ///
    /// Where both bars meet, AppKit leaves a bare corner square; `tile()` covers it with the
    /// card's own background so it disappears into the console.
    final class ConsoleScrollView: NSScrollView {
        private let corner = CornerFillView()

        override var scrollerStyle: NSScroller.Style {
            get { .legacy }
            set {}
        }

        override func tile() {
            super.tile()
            verticalScroller?.scrollerStyle = .legacy
            horizontalScroller?.scrollerStyle = .legacy
            guard let vertical = verticalScroller, !vertical.isHidden,
                  let horizontal = horizontalScroller, !horizontal.isHidden else {
                corner.isHidden = true
                return
            }
            if corner.superview !== self { addSubview(corner) }
            corner.isHidden = false
            corner.frame = NSRect(x: vertical.frame.minX, y: horizontal.frame.minY,
                                  width: vertical.frame.width,
                                  height: horizontal.frame.height)
        }

        private final class CornerFillView: NSView {
            override func draw(_ dirtyRect: NSRect) {
                Ink.codeBackground.setFill()
                bounds.fill()
            }
        }
    }

    /// Drives `reveal` toward `target` with an ease-out, reporting every step through
    /// `onHeightChange` so the page slides with the console instead of jumping. The driver is
    /// a plain main-run-loop timer: the console's height lives in the document stack's measure
    /// pass, which no Core Animation property can reach.
    private func animateReveal(to target: CGFloat, completion: (() -> Void)? = nil) {
        revealTimer?.invalidate()
        revealTimer = nil

        let step: (CGFloat) -> Void = { [weak self] reveal in
            guard let self else { return }
            self.reveal = reveal
            alphaValue = reveal
            onHeightChange?()
        }

        let duration = CodeComponentView.outputRevealDuration
        guard duration > 0, target != reveal else {
            step(target)
            completion?()
            return
        }

        let start = reveal
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let t = min(1, Date().timeIntervalSince(began) / duration)
            let eased = 1 - pow(1 - t, 3)
            step(start + (target - start) * CGFloat(eased))
            if t >= 1 {
                timer.invalidate()
                self?.revealTimer = nil
                completion?()
            }
        }
        revealTimer = timer
        // Common modes, so the unfold does not freeze while the reader is mid-scroll.
        RunLoop.main.add(timer, forMode: .common)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
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
