import AppKit

/// One run's console: a card of its own below the code card — the same headered-card chrome,
/// with the run's start time as the label, its own close button, and the result text,
/// scrollable past the cap. Each console unfolds on arrival and folds away when closed,
/// independently of its siblings.
///
/// A view over a `RunSession`, never the run's owner: the session holds the transcript and the
/// result, and every console bound to it — the reading pane's, a peek card's — renders the same
/// run. Closing any of them closes the session, which folds them all.
///
/// Layer-masked, unlike other cards: its height animates, and an NSView does not clip its
/// subviews on its own — a half-revealed console would otherwise draw over whatever sits
/// below it. The card chrome is still painted in `draw(_:)`, so it grows with the reveal and
/// dynamic colors keep resolving at draw time.
final class RunOutputPanel: HeaderedCardView {

    let session: RunSession

    /// The finished run — nil while the command is still running. Read off the session, so
    /// every bound console agrees.
    var entry: RunSession.Entry? { session.entry }
    var isRunning: Bool { session.isRunning }
    /// What the pty has produced so far — the live body until the command exits.
    var liveTranscript: TerminalSnapshot { session.liveTranscript }

    /// Re-measure hook: the owning card forwards this to its host on every animation step.
    var onHeightChange: (() -> Void)?
    /// Fired after the fold-away finishes; the owning card removes the panel.
    var onClose: ((RunOutputPanel) -> Void)?

    /// How far the console has unfolded, 0…1. Height and alpha both follow it.
    private(set) var reveal: CGFloat = 0
    private var revealTimer: Timer?
    private var sessionToken: UUID?

    private(set) var closeButton: NSButton!
    private let scroll = ConsoleScrollView()
    private let textView = TextComponentView()
    private let spinner = NSProgressIndicator()

    /// A console's text scrolls internally past this, so one chatty command cannot turn the
    /// page into its log.
    static let maxOutputTextHeight: CGFloat = 220
    /// The body never collapses below one row, so a console that has printed nothing yet is
    /// still visibly a console.
    static let minimumBodyHeight: CGFloat = 16
    /// How long a console takes to unfold or fold away. A `static var` so tests can zero it
    /// and assert on final geometry.
    static var revealDuration: TimeInterval = 0.22

    override var cardFillColor: NSColor { Ink.codeBackground }

    init(session: RunSession, metrics: DocumentMetrics) {
        self.session = session
        super.init(metrics: metrics, label: Self.timeFormatter.string(from: session.startedAt))
        // The owning card frames every console from its own `layout()`, so the frame must be
        // the authority here — the same as the code body's. Left constraint-driven, the panel
        // has no constraints of its own, so Auto Layout solves its header against the card's
        // fallback intrinsic width instead of the width it is actually given: the trailing
        // accessories land past the panel's right edge, where `masksToBounds` clips them, and
        // the console loses its spinner and close button.
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        layer?.masksToBounds = true
        alphaValue = 0

        // Activity lives in the header — the body belongs to the pty from the first byte.
        // A console adopted after its run already finished never had activity to show.
        if session.isRunning {
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            headerAccessories.addArrangedSubview(spinner)
        }

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
        if let entry = session.entry {
            textView.configure(with: Self.outputText(entry.output, metrics: metrics),
                               kind: .paragraph)
            setAccessibilityLabel("Command output from \(headerLabel.stringValue)")
        } else {
            if !session.liveTranscript.isEmpty {
                textView.configure(with: Self.liveText(session.liveTranscript,
                                                       metrics: metrics), kind: .paragraph)
            }
            setAccessibilityLabel("Command running since \(headerLabel.stringValue)")
        }

        sessionToken = session.addObserver { [weak self] event in
            guard let self else { return }
            switch event {
            case .output: sessionOutputChanged()
            case .finished: sessionFinished()
            case .closed: foldAway()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        revealTimer?.invalidate()
        if let sessionToken { session.removeObserver(sessionToken) }
    }

    /// A fresh slice of the pty stream: the full transcript so far, shown live. The console
    /// grows with it (up to the cap) and keeps the tail in view, the way a terminal does —
    /// unless the reader has scrolled back to read, in which case their place is theirs.
    private func sessionOutputChanged() {
        // Decided before the text changes: "was the reader at the tail" only means anything
        // against the old content.
        pinTailAfterLayout = isScrolledToTail
        invalidateBodyCache()
        textView.configure(with: Self.liveText(session.liveTranscript, metrics: metrics),
                           kind: .paragraph)
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
    private lazy var outputLineHeight: CGFloat = Self.lineHeight(metrics: metrics)

    /// Set when a live update arrives with the reader at the tail; consumed by `layout()`,
    /// because the scroll must happen *after* the text view has grown to hold the new tail —
    /// scrolling first is how the last line ends up half-clipped below the viewport.
    private var pinTailAfterLayout = false

    /// The command exited: the live view settles into the logged result — same body, plus the
    /// exit line when it failed. The console eases from its live height to the result's height
    /// by re-entering the reveal from the ratio of the two, so the change is animated rather
    /// than a jump.
    private func sessionFinished() {
        guard let entry = session.entry else { return }
        let width = max(1, bounds.width)
        // The session already holds the result, so the pre-finish height is derived from the
        // transcript the live view was showing a moment ago.
        let runningHeight = Self.settledHeight(
            bodyText: Self.liveText(session.liveTranscript, metrics: metrics),
            width: width, metrics: metrics)

        invalidateBodyCache()
        spinner.stopAnimation(nil)
        spinner.removeFromSuperview()
        textView.configure(with: Self.outputText(entry.output, metrics: metrics),
                           kind: .paragraph)
        setAccessibilityLabel("Command output from \(headerLabel.stringValue)")

        let finishedHeight = fullHeight(width: width)
        if reveal >= 1, finishedHeight > 0, runningHeight != finishedHeight,
           Self.revealDuration > 0 {
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
    ///
    /// Cached, with its measured size, until the transcript or the result changes: both are
    /// read on every measure, layout, and draw pass — several times each — and rebuilding and
    /// re-laying-out a whole transcript per scroll frame is what made pages with consoles slow.
    private var cachedBodyText: NSAttributedString?
    private var cachedContentSize: NSSize?

    private func invalidateBodyCache() {
        cachedBodyText = nil
        cachedContentSize = nil
    }

    private var bodyText: NSAttributedString {
        if let cachedBodyText { return cachedBodyText }
        let text = Self.bodyText(for: session, metrics: metrics)
        cachedBodyText = text
        return text
    }

    /// The transcript's laid-out size at the unwrapped measure width.
    private var contentSize: NSSize {
        if let cachedContentSize { return cachedContentSize }
        let size = TextMeasurer.shared.size(of: bodyText, width: Self.unwrappedMeasureWidth)
        cachedContentSize = size
        return size
    }

    /// The session's body as attributed text — the logged result once finished, the live
    /// transcript before. Static so a store can measure a console no view exists for.
    static func bodyText(for session: RunSession, metrics: DocumentMetrics) -> NSAttributedString {
        if let entry = session.entry { return outputText(entry.output, metrics: metrics) }
        return liveText(session.liveTranscript, metrics: metrics)
    }

    // MARK: Console type

    /// The point size console output is set at.
    ///
    /// The same size as the code in the card above it, rather than the caption size the chrome
    /// uses. A console is not chrome: it is output a reader reads line by line, often the
    /// longest stretch of text on the page, and setting it a tier below the code that produced
    /// it made the answer smaller than the question. It tracks the reading size through the
    /// ramp, so ⌘+ grows it with everything else.
    static func pointSize(metrics: DocumentMetrics) -> CGFloat {
        metrics.ramp.mono().pointSize
    }

    /// Extra leading between console rows, as a fraction of the type size.
    ///
    /// Mono faces set solid are hard to scan: a terminal log is mostly short lines with a lot
    /// of punctuation, and without a gap the eye loses its row on the way back to the left
    /// margin. This is roughly the quarter-em terminals themselves use.
    static let lineSpacingRatio: CGFloat = 0.26

    /// The paragraph style every console row carries. Shared by the styled runs and the plain
    /// ones — a row missing it would sit tighter than its neighbours.
    static func paragraphStyle(size: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = (size * lineSpacingRatio).rounded()
        // Console lines never wrap; they scroll sideways, which the panel sizes for.
        style.lineBreakMode = .byClipping
        return style
    }

    /// The result as attributed text: the transcript in the colors the command asked for,
    /// stderr and a non-zero exit in red, and an explicit "(no output)" so a silent success
    /// never looks like a dead button. Static so the height measure and the rendered panel
    /// read the same string.
    static func outputText(_ result: ProcessRunner.Output,
                           metrics: DocumentMetrics) -> NSAttributedString {
        let size = pointSize(metrics: metrics)
        let font = TypeRamp.fixedPitchMono(ofSize: size)
        let paragraph = paragraphStyle(size: size)
        let out = NSMutableAttributedString()
        func separator() {
            guard out.length > 0 else { return }
            out.append(NSAttributedString(string: "\n", attributes: [.font: font,
                                                                    .paragraphStyle: paragraph]))
        }
        func line(_ text: String, _ color: NSColor) {
            separator()
            out.append(NSAttributedString(string: text,
                                          attributes: [.font: font, .foregroundColor: color,
                                                       .paragraphStyle: paragraph]))
        }
        if result.status != 0 { line("exit \(result.status)", .systemRed) }
        if !result.transcript.isEmpty {
            separator()
            out.append(liveText(result.transcript, metrics: metrics))
        } else if !result.outputText.isEmpty {
            // No parser behind this one — the non-pty paths, and hosts that fabricate a
            // result. Plain body ink, as it always was.
            line(result.outputText, Ink.body)
        }
        if !result.errorText.isEmpty { line(result.errorText, .systemRed) }
        if out.length == 0 { line("(no output)", Ink.tertiary) }
        return out
    }

    /// A transcript as attributed text, one run at a time — the same mono face throughout,
    /// with each run's own colors, weight, and decoration.
    static func liveText(_ transcript: TerminalSnapshot,
                         metrics: DocumentMetrics) -> NSAttributedString {
        let size = pointSize(metrics: metrics)
        let out = NSMutableAttributedString()
        for (index, line) in transcript.lines.enumerated() {
            if index > 0 {
                // The newline carries plain attributes: a line ending inside a background
                // color would otherwise paint that color out to the edge of the console.
                out.append(NSAttributedString(string: "\n",
                                              attributes: attributes(for: .plain, size: size)))
            }
            for run in line.runs where !run.text.isEmpty {
                out.append(NSAttributedString(string: run.text,
                                              attributes: attributes(for: run.style, size: size)))
            }
        }
        return out
    }

    /// One run's style as text attributes.
    static func attributes(for style: TerminalCellStyle,
                           size: CGFloat) -> [NSAttributedString.Key: Any] {
        let (foreground, background) = colors(for: style)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: TypeRamp.fixedPitchMono(ofSize: size, bold: style.bold, italic: style.italic),
            .foregroundColor: foreground,
            .paragraphStyle: paragraphStyle(size: size),
        ]
        if let background { attributes[.backgroundColor] = background }
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let color = concrete(style.underlineColor) {
                attributes[.underlineColor] = color
            }
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    /// A style's two painted colors. The background is nil when nothing asked for one, so an
    /// ordinary run leaves the card's own fill showing through rather than painting over it.
    ///
    /// The order matters. `inverse` swaps the pair *after* the defaults have been resolved to
    /// real colors: swapping first would hand the text `.default` as its color and leave the
    /// background unpainted, which draws the text in the color it is sitting on — a hole where
    /// the reversed word should be. `faint` then blends toward whatever the text ended up
    /// sitting on, which for reversed text is the color that was just swapped in.
    static func colors(for style: TerminalCellStyle) -> (foreground: NSColor,
                                                         background: NSColor?) {
        let askedForeground = concrete(style.foreground) ?? Ink.body
        let askedBackground = concrete(style.background)

        var foreground = askedForeground
        var background = askedBackground
        if style.inverse {
            foreground = askedBackground ?? Ink.codeBackground
            background = askedForeground
        }
        if style.faint {
            let backdrop = background ?? Ink.codeBackground
            foreground = foreground.blending(0.45, toward: backdrop) ?? foreground
        }
        return (foreground, background)
    }

    /// A terminal color as a concrete one — nil for `.default`, which only the caller knows
    /// how to fill in.
    private static func concrete(_ color: TerminalColor) -> NSColor? {
        switch color {
        case .default: return nil
        case .palette(let index): return Ink.terminal(index)
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                           blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    /// Console lines never wrap, so heights are measured at effectively infinite width — a
    /// long line costs sideways scrolling, never extra rows.
    static let unwrappedMeasureWidth: CGFloat = 1_000_000

    /// One line of console output at these metrics. The single formula both the panel and the
    /// view-less measure use — two answers here and the page jumps when a view is created.
    ///
    /// Memoized by the only thing it depends on, the mono face's size: it is read from the
    /// capped-height path, which every measure, layout, and draw pass of a console taller than
    /// the cap goes through. It used to be a per-panel `lazy var`; sharing the formula with the
    /// store's view-less measure is what made it static, and a static that re-ran TextKit per
    /// call would hand back the per-pass cost the console caches everything else to avoid.
    private static var lineHeights: [CGFloat: CGFloat] = [:]

    /// Measured as the *advance* from one row to the next — the difference between a two-row
    /// transcript and a one-row one — not as the height of a single row. The two stopped being
    /// the same when console rows gained their extra leading, and the cap below rounds the
    /// viewport down to whole rows by dividing by this: measured without the leading it would
    /// round to a viewport that is a row-and-a-bit too tall, which is exactly the half-clipped
    /// last line the rounding exists to prevent.
    static func lineHeight(metrics: DocumentMetrics) -> CGFloat {
        let size = pointSize(metrics: metrics)
        if let cached = lineHeights[size] { return cached }
        func height(_ text: String) -> CGFloat {
            TextComponentView.height(of: liveText(.plainText(text), metrics: metrics),
                                     width: 1000)
        }
        let advance = max(1, height("x\nx") - height("x"))
        lineHeights[size] = advance
        return advance
    }

    func fullHeight(width: CGFloat) -> CGFloat {
        Self.settledHeight(contentSize: contentSize, width: width, metrics: metrics)
    }

    /// A console's full (settled, reveal = 1) height for `bodyText` at `width`. Static so a
    /// session store can answer the stack's measure pass for a block whose card has never
    /// been created.
    static func settledHeight(bodyText: NSAttributedString, width: CGFloat,
                              metrics: DocumentMetrics) -> CGFloat {
        settledHeight(contentSize: TextMeasurer.shared.size(of: bodyText,
                                                            width: unwrappedMeasureWidth),
                      width: width, metrics: metrics)
    }

    /// The same, for a caller that already has the transcript's laid-out size — the panel
    /// itself, which caches it rather than re-running TextKit on every pass.
    static func settledHeight(contentSize: NSSize, width: CGFloat,
                              metrics: DocumentMetrics) -> CGFloat {
        let insets = metrics.codeCardInsets
        return CardChrome.headerHeight + insets.bodyTop
            + scrollViewportHeight(forContent: contentSize, panelWidth: width,
                                   metrics: metrics)
            + insets.bodyBottom
    }

    /// The scroll view's height at `width`: the whole-line text area, plus the horizontal
    /// bar's thickness when the widest line overflows sideways. Legacy bars are carved out of
    /// the viewport, so a viewport sized to exactly the text would lose its last line to the
    /// bar. Deterministic, because the console pins its scroller style.
    private static func scrollViewportHeight(forContent content: NSSize,
                                             panelWidth width: CGFloat,
                                             metrics: DocumentMetrics) -> CGFloat {
        let body = cappedBodyHeight(for: content.height, metrics: metrics)
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
    private static func cappedBodyHeight(for textHeight: CGFloat,
                                         metrics: DocumentMetrics) -> CGFloat {
        guard textHeight > maxOutputTextHeight else {
            return max(minimumBodyHeight, textHeight)
        }
        let line = lineHeight(metrics: metrics)
        let whole = (maxOutputTextHeight / line).rounded(.down) * line
        return max(minimumBodyHeight, whole)
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
        let content = contentSize
        // The document is as wide as its widest line; a narrower transcript still fills the
        // viewport so selection and clicks behave across its whole width.
        textView.frame = NSRect(x: 0, y: 0,
                                width: max(viewportWidth, content.width),
                                height: max(1, content.height))
        scroll.frame = NSRect(
            x: gutter,
            y: CardChrome.headerHeight + insets.bodyTop,
            width: viewportWidth,
            height: Self.scrollViewportHeight(forContent: content, panelWidth: width,
                                              metrics: metrics)
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

    /// Shows the console already settled — the adoption path, for a view created after the
    /// session it renders was already up. Only a run the view witnessed beginning unfolds.
    func revealInstantly() {
        revealTimer?.invalidate()
        revealTimer = nil
        reveal = 1
        alphaValue = 1
        needsLayout = true
    }

    /// Folds the console away and hands it back to the owner — the session-closed path, and
    /// the card's when a run produced nothing to show.
    func foldAway() {
        animateReveal(to: 0) { [weak self] in
            guard let self else { return }
            onClose?(self)
        }
    }

    /// The click closes the *session*: the fold arrives back through the `.closed` event, on
    /// this console and on every other one bound to the same run.
    @objc private func closeTapped() { session.close() }

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

        let duration = Self.revealDuration
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

extension RunSessionStore {
    /// What a block's consoles add to its code card's height at `width` — the measure the
    /// document stack falls back on when the card's view has never been created, so a run
    /// started from a peek still reserves its space on the page. Settled heights: a view that
    /// exists answers with its own reveal-accurate `outputPanelHeight` instead.
    func consoleHeight(for key: RunBlockKey, width: CGFloat,
                       metrics: DocumentMetrics) -> CGFloat {
        sessions(for: key).reduce(0) { total, session in
            total + CodeComponentView.consoleGap
                + RunOutputPanel.settledHeight(
                    bodyText: RunOutputPanel.bodyText(for: session, metrics: metrics),
                    width: width, metrics: metrics)
        }
    }
}
