import AppKit
import XCTest
@testable import FolioKit

/// A code block fenced as a shell language is executable: its card gets a Run button that
/// executes the source at the document's project root and reports the output.
final class RunnableCodeBlockTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private var scratch: URL!
    private var savedRevealDuration: TimeInterval = 0

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-runnable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Geometry assertions want the panel's final state, not a frame mid-unfold.
        savedRevealDuration = RunOutputPanel.revealDuration
        RunOutputPanel.revealDuration = 0
    }

    override func tearDownWithError() throws {
        RunOutputPanel.revealDuration = savedRevealDuration
        try FileManager.default.removeItem(at: scratch)
    }

    private func makeDocument(_ markdown: String, at directory: URL? = nil) throws -> MarkdownDocument {
        let url = (directory ?? scratch).appendingPathComponent("doc.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return try MarkdownDocument(url: url)
    }

    private func lines(_ code: String) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [.font: metrics.ramp.mono()])
    }

    /// Invokes the button's action directly — the file's convention for header buttons, since
    /// `performClick` routes through `NSApplication.sendAction`, which needs a live app session.
    private func click(_ button: NSButton) {
        _ = button.target?.perform(button.action, with: button)
    }

    private func buttons(under view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            var found = buttons(under: subview)
            if let button = subview as? NSButton { found.append(button) }
            return found
        }
    }

    // MARK: Language plumbing

    func testFenceLanguageReachesTheComponent() throws {
        let document = try makeDocument("""
        # T

        ```bash
        echo hi
        ```

        ```python
        print("hi")
        ```
        """)
        let built = AttributedDocumentBuilder(document: document, metrics: metrics).build()
        let languages = built.components.compactMap { component -> String? in
            guard case .code(_, _, let language, _) = component.content else { return nil }
            return language ?? "(none)"
        }
        XCTAssertEqual(languages, ["bash", "python"])
    }

    /// An HTML block renders as a source card labelled "html" but declares no language, so it
    /// must never look runnable.
    func testHTMLBlockCarriesNoLanguage() throws {
        let document = try makeDocument("# T\n\n<div>\n<b>x</b>\n</div>\n")
        let built = AttributedDocumentBuilder(document: document, metrics: metrics).build()
        let card = built.components.first { if case .code = $0.content { return true } else { return false } }
        guard case .code(let label, _, let language, _)? = card?.content else {
            return XCTFail("expected an html source card")
        }
        XCTAssertEqual(label, "html")
        XCTAssertNil(language)
    }

    // MARK: The Run button

    func testOnlyShellCardsGetARunButton() {
        for shell in ["bash", "sh", "shell", "zsh"] {
            let card = CodeComponentView(label: shell, source: "echo hi", language: shell,
                                         lines: lines("echo hi"), metrics: metrics,
                                         host: RecordingHost())
            XCTAssertNotNil(card.runButton, "\(shell) should be runnable")
        }
        for other in ["python", "fish", "swift"] {
            let card = CodeComponentView(label: other, source: "x", language: other,
                                         lines: lines("x"), metrics: metrics,
                                         host: RecordingHost())
            XCTAssertNil(card.runButton, "\(other) must not be runnable")
        }
        let unlabelled = CodeComponentView(label: "code", source: "x", language: nil,
                                           lines: lines("x"), metrics: metrics,
                                           host: RecordingHost())
        XCTAssertNil(unlabelled.runButton, "a fence with no language must not be runnable")
    }

    func testRunOpensAConsoleAndHoldsTheButtonUntilTheCommandExits() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "echo hi", language: "bash",
                                     lines: lines("echo hi"), metrics: metrics, host: host)
        let button = try XCTUnwrap(card.runButton)
        XCTAssertTrue(button.isEnabled, "an idle block is runnable")

        click(button)
        XCTAssertEqual(host.ran, ["echo hi"])
        XCTAssertFalse(button.isEnabled, "runs are serial: the button is out while one runs")
        let panel = try XCTUnwrap(card.runPanel,
                                  "a console must appear the moment the run starts")
        XCTAssertTrue(panel.isRunning)
        XCTAssertNil(card.runOutput, "no result yet — the command is still running")
        XCTAssertGreaterThan(card.outputPanelHeight, 0,
                             "the running console must already take space on the page")

        // The pty streams into the running console as the command produces output.
        let emptyHeight = panel.fullHeight
        host.emitOutput("hello\nworld\nagain\n")
        XCTAssertEqual(panel.liveTranscript.plainText, "hello\nworld\nagain\n",
                       "live output must land in the console before the command exits")
        XCTAssertTrue(panel.isRunning)
        XCTAssertEqual(panel.fullHeight, emptyHeight,
                       "live output scrolls inside the console — it must not resize it")

        // A second click mid-run starts nothing: one command at a time.
        click(button)
        XCTAssertEqual(host.ran, ["echo hi"], "a click mid-run must not start a second command")
        XCTAssertTrue(card.runPanel === panel, "and must not disturb the running console")

        host.finishPendingRuns(with: ProcessRunner.Output(status: 0, outputText: "hi",
                                                          errorText: ""))
        XCTAssertFalse(panel.isRunning, "the console must carry its run to completion")
        XCTAssertEqual(card.runEntry?.output.outputText, "hi")
        XCTAssertTrue(button.isEnabled, "the button comes back when the command exits")
    }

    /// The serial gate is the document's, not the block's: while one block runs, no block in
    /// the same document will start a second command at the same project root.
    func testARunningBlockPutsEveryOtherBlocksRunButtonOut() throws {
        let store = RunSessionStore()
        let documentURL = URL(fileURLWithPath: "/tmp/serial-doc.md")
        func card(at location: Int, host: RecordingHost) -> CodeComponentView {
            let view = CodeComponentView(label: "bash", source: "echo \(location)",
                                         language: "bash", lines: lines("echo hi"),
                                         metrics: metrics, host: host)
            view.bindRunSessions(
                key: RunBlockKey(documentURL: documentURL, location: location), store: store)
            return view
        }
        let firstHost = RecordingHost()
        let secondHost = RecordingHost()
        let first = card(at: 10, host: firstHost)
        let second = card(at: 90, host: secondHost)
        let secondButton = try XCTUnwrap(second.runButton)

        click(try XCTUnwrap(first.runButton))
        XCTAssertFalse(secondButton.isEnabled,
                       "a run anywhere in the document puts every Run button out")

        click(secondButton)
        XCTAssertTrue(secondHost.ran.isEmpty, "the second block must not run in parallel")
        XCTAssertNil(second.runPanel, "and must not open a console it never ran")

        firstHost.finishPendingRuns(with: ProcessRunner.Output(status: 0, outputText: "done",
                                                               errorText: ""))
        XCTAssertTrue(secondButton.isEnabled, "the first run exiting frees the others")
        click(secondButton)
        XCTAssertEqual(secondHost.ran, ["echo 90"])
        XCTAssertNotNil(second.runPanel)
        XCTAssertNotNil(first.runPanel,
                        "the finished block keeps its console while another block runs")
    }

    func testClosingARunningConsoleDiscardsItsLateResult() throws {
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "sleep 5", language: "bash",
                                     lines: lines("sleep 5"), metrics: metrics, host: host)

        click(try XCTUnwrap(card.runButton))
        let panel = try XCTUnwrap(card.runPanel)

        // The reader gives up on it before it exits.
        click(panel.closeButton)
        XCTAssertNil(card.runPanel)
        XCTAssertTrue(try XCTUnwrap(card.runButton).isEnabled,
                      "dismissing a running console frees the button")

        // The command exits later — its console is gone, so the result goes nowhere.
        host.finishPendingRuns(with: ProcessRunner.Output(status: 0, outputText: "late",
                                                          errorText: ""))
        XCTAssertNil(card.runPanel)
        XCTAssertNil(card.runOutput)
    }

    func testAConsoleGrowsTheCardOnceAndDismissalShrinksItBack() throws {
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "echo hi", language: "bash",
                                     lines: lines("echo hi"), metrics: metrics, host: host)
        let width: CGFloat = 500
        let bare = card.sizeThatFits(width: width).height

        click(try XCTUnwrap(card.runButton))
        let running = card.sizeThatFits(width: width).height
        XCTAssertGreaterThan(running, bare,
                             "the running console must already grow the card")

        host.finishPendingRuns(with: ProcessRunner.Output(status: 0, outputText: "hi\nhi\nhi",
                                                          errorText: ""))
        XCTAssertNotNil(card.runOutput)
        XCTAssertEqual(card.sizeThatFits(width: width).height, running,
                       "the result must land inside the console the run already reserved")
        XCTAssertGreaterThan(host.heightChanges.count, 0,
                             "the card must ask its host to re-measure it")

        // The console's own close button folds it away and re-measures again.
        let close = try XCTUnwrap(buttons(under: card).first { $0.toolTip == "Close result" })
        click(close)
        XCTAssertNil(card.runOutput)
        XCTAssertEqual(card.sizeThatFits(width: width).height, bare,
                       "closing must restore the bare height")
    }

    /// The console's header buttons must land inside the console.
    ///
    /// A panel left constraint-driven has no constraints of its own, so Auto Layout solves its
    /// header against the card's fallback intrinsic width rather than the width the card
    /// actually frames it at — the trailing accessories end up past the panel's right edge,
    /// where its layer mask clips them, and the console loses its spinner and close button.
    /// Reproduced through a window, because that is what runs the constraint pass.
    func testConsoleHeaderButtonsStayInsideTheConsole() throws {
        let width: CGFloat = 520
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "echo hi", language: "bash",
                                     lines: lines("echo hi"), metrics: metrics, host: host)
        click(try XCTUnwrap(card.runButton))
        host.emitOutput("tick 1\ntick 2\n")

        let height = card.sizeThatFits(width: width).height
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = content
        content.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)
        content.layoutSubtreeIfNeeded()

        let panel = try XCTUnwrap(card.runPanel)
        let accessories = panel.headerAccessories.frame
        XCTAssertGreaterThan(accessories.width, 0,
                             "a running console has a spinner and a close button")
        XCTAssertLessThanOrEqual(accessories.maxX, panel.bounds.width,
                                 "the close button must not sit past the console's edge")
        XCTAssertGreaterThanOrEqual(accessories.minX, 0)
        XCTAssertLessThanOrEqual(accessories.maxY, CardChrome.headerHeight,
                                 "the accessories belong on the header strip")
    }

    /// However much a command prints — nothing at all, or five hundred lines — the console is
    /// the same size. Sized to its content it moved on every tick of a live transcript, and a
    /// reader who ran a block twice watched the page shuffle under the pointer.
    func testTheConsoleIsTheSameHeightWhateverTheCommandPrints() {
        func card(printing text: String) -> CodeComponentView {
            let view = CodeComponentView(label: "bash", source: "yes", language: "bash",
                                         lines: lines("yes"), metrics: metrics,
                                         host: RecordingHost())
            view.showRunOutput(ProcessRunner.Output(status: 0, outputText: text, errorText: ""))
            return view
        }
        let silent = card(printing: "").outputPanelHeight
        let oneLine = card(printing: "hi").outputPanelHeight
        let chatty = card(printing: (1...500).map { "line \($0)" }.joined(separator: "\n"))
            .outputPanelHeight

        XCTAssertGreaterThan(silent, 0, "even an empty console reserves its space")
        XCTAssertEqual(oneLine, silent, "one line of output must not resize the console")
        XCTAssertEqual(chatty, silent,
                       "a chatty command must scroll inside the console, not grow it")
    }

    /// The live console and the one showing the exited command's result are the same size, so
    /// the moment a command finishes moves nothing.
    func testFinishingACommandDoesNotResizeItsConsole() throws {
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "make test", language: "bash",
                                     lines: lines("make test"), metrics: metrics, host: host)
        click(try XCTUnwrap(card.runButton))
        let running = card.outputPanelHeight
        host.emitOutput("building\nlinking\n")
        XCTAssertEqual(card.outputPanelHeight, running, "live output moves nothing")

        host.finishPendingRuns(with: ProcessRunner.Output(status: 1, outputText: "",
                                                          errorText: "failed"))
        XCTAssertEqual(card.outputPanelHeight, running,
                       "settling into the logged result — exit line and all — moves nothing")
    }

    /// A block keeps one console. Running it again replaces what is there rather than
    /// stacking a second card under the code, so the page cannot grow a log of old runs.
    func testARerunReplacesTheBlocksConsole() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "date", language: "bash",
                                     lines: lines("date"), metrics: metrics, host: host)
        card.frame = NSRect(x: 0, y: 0, width: width, height: 0)

        card.showRunOutput(ProcessRunner.Output(status: 0, outputText: "first run",
                                                errorText: ""))
        let first = try XCTUnwrap(card.runPanel)
        let single = card.outputPanelHeight

        card.showRunOutput(ProcessRunner.Output(status: 0, outputText: "second run",
                                                errorText: ""))
        let second = try XCTUnwrap(card.runPanel)
        XCTAssertFalse(first === second, "the re-run must open a console of its own")
        XCTAssertEqual(card.runOutput?.outputText, "second run",
                       "and the block must show the latest result")
        XCTAssertEqual(card.outputPanelHeight, single,
                       "a re-run must cost the page exactly one console, the same size")

        card.frame = NSRect(x: 0, y: 0, width: width,
                            height: card.sizeThatFits(width: width).height)
        card.layoutSubtreeIfNeeded()
        XCTAssertNil(first.superview, "the replaced console must leave the card")
        XCTAssertEqual(card.subviews.compactMap { $0 as? RunOutputPanel }, [second],
                       "one block, one console")

        click(second.closeButton)
        XCTAssertNil(card.runPanel)
        XCTAssertNil(card.runOutput)
        XCTAssertEqual(card.outputPanelHeight, 0)
    }

    func testTheViewportIsWholeLinesOnly() throws {
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "make test", language: "bash",
                                     lines: lines("make test"), metrics: metrics, host: host)
        click(try XCTUnwrap(card.runButton))
        host.emitOutput((1...200).map { "line \($0)" }.joined(separator: "\n"))

        let panel = try XCTUnwrap(card.runPanel)
        let insets = metrics.codeCardInsets
        let body = panel.fullHeight
            - CardChrome.headerHeight - insets.bodyTop - insets.bodyBottom
        // The panel's own advance from one row to the next, which is a row's height *plus*
        // its leading — measuring a lone "x" would answer the height alone and no longer
        // divides the viewport evenly.
        let line = RunOutputPanel.lineHeight(metrics: metrics)
        XCTAssertEqual(body, RunOutputPanel.bodyHeight(metrics: metrics))
        XCTAssertEqual(body, CGFloat(RunOutputPanel.outputRows) * line,
                       "the console shows exactly the rows it promises")
        XCTAssertEqual(body.truncatingRemainder(dividingBy: line), 0,
                       "a viewport of 8½ lines shows half a string at its edge")
    }

    func testLiveUpdatesKeepTheTailFullyVisible() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "make test", language: "bash",
                                     lines: lines("make test"), metrics: metrics, host: host)
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        click(try XCTUnwrap(card.runButton))

        func layoutForCurrentContent() {
            card.frame = NSRect(x: 0, y: 0, width: width,
                                height: card.sizeThatFits(width: width).height)
            card.layoutSubtreeIfNeeded()
        }

        host.emitOutput((1...100).map { "line \($0)" }.joined(separator: "\n"))
        layoutForCurrentContent()

        let panel = try XCTUnwrap(card.runPanel)
        let scroll = try XCTUnwrap(
            panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, text.frame.height - 1,
                                    "a live update must land with the tail fully in view")

        // The reader scrolls back; the next update must not yank them to the tail.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        host.emitOutput((1...120).map { "line \($0)" }.joined(separator: "\n"))
        layoutForCurrentContent()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0,
                       "a reader who scrolled back keeps their place")
    }

    func testLongLinesScrollSidewaysInsteadOfWrapping() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "ls", language: "bash",
                                     lines: lines("ls"), metrics: metrics, host: host)
        click(try XCTUnwrap(card.runButton))
        host.emitOutput(String(repeating: "a very long unbroken line ", count: 40))

        card.frame = NSRect(x: 0, y: 0, width: width,
                            height: card.sizeThatFits(width: width).height)
        card.layoutSubtreeIfNeeded()

        let panel = try XCTUnwrap(card.runPanel)
        let line = RunOutputPanel.lineHeight(metrics: metrics)
        let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThan(text.frame.height, line * 2,
                          "one long line must stay one line, not wrap into a paragraph")
        XCTAssertGreaterThan(text.frame.width, scroll.contentView.bounds.width,
                             "the long line must extend into a horizontal scroll")
    }

    /// A tall transcript of short lines scrolls down, and only down.
    ///
    /// The document view is stretched to fill the text area so a narrow transcript is still
    /// selectable across the console's width. Stretched to the *whole* viewport it overflows
    /// sideways by exactly the vertical bar's thickness the moment that bar appears, and
    /// summons a horizontal bar with nothing to scroll — which then carves a row out of a
    /// console that can no longer grow to replace it.
    func testATallTranscriptOfShortLinesNeedsNoHorizontalScroll() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "seq 1 40", language: "bash",
                                     lines: lines("seq 1 40"), metrics: metrics, host: host)
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        click(try XCTUnwrap(card.runButton))
        host.emitOutput((1...40).map { "line \($0)" }.joined(separator: "\n"))

        card.frame = NSRect(x: 0, y: 0, width: width,
                            height: card.sizeThatFits(width: width).height)
        card.layoutSubtreeIfNeeded()

        let panel = try XCTUnwrap(card.runPanel)
        let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(text.frame.height, scroll.contentView.bounds.height,
                             "forty lines must overflow downward — that is the fixture")
        XCTAssertLessThanOrEqual(text.frame.width, scroll.contentView.bounds.width,
                                 "short lines must not overflow sideways")
        XCTAssertEqual(scroll.contentView.bounds.height,
                       RunOutputPanel.bodyHeight(metrics: metrics),
                       "so no horizontal bar carves a row out of the viewport")
        XCTAssertEqual(scroll.contentView.bounds.height.truncatingRemainder(
            dividingBy: RunOutputPanel.lineHeight(metrics: metrics)), 0,
            "and the reader sees whole rows")
    }

    /// The horizontal scroll bar is carved out of the viewport, so a long line costs a row of
    /// it — but never so much that two lines of output stop being fully visible.
    func testAShortTranscriptWithALongLineNeedsNoVerticalScroll() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "swift build", language: "bash",
                                     lines: lines("swift build"), metrics: metrics, host: host)
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        click(try XCTUnwrap(card.runButton))
        host.emitOutput("Another instance of SwiftPM is already running using "
            + String(repeating: "/a/very/long/path", count: 20) + "\nwaiting…")

        card.frame = NSRect(x: 0, y: 0, width: width,
                            height: card.sizeThatFits(width: width).height)
        card.layoutSubtreeIfNeeded()

        let panel = try XCTUnwrap(card.runPanel)
        let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height, text.frame.height,
                                    "two lines of output must be fully visible, "
                                        + "horizontal scroller or not")
    }

    func testOutputUnfoldsInStepsAndLandsAtFullHeight() {
        let width: CGFloat = 500
        let result = ProcessRunner.Output(status: 0, outputText: "line one\nline two",
                                          errorText: "")

        // Reference: the settled height, from a card with the animation zeroed.
        let settled = CodeComponentView(label: "bash", source: "x", language: "bash",
                                        lines: lines("x"), metrics: metrics,
                                        host: RecordingHost())
        settled.showRunOutput(result)
        let fullHeight = settled.outputPanelHeight
        XCTAssertGreaterThan(fullHeight, 0)

        RunOutputPanel.revealDuration = 0.25
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "x", language: "bash",
                                     lines: lines("x"), metrics: metrics, host: host)
        card.showRunOutput(result)
        XCTAssertEqual(card.outputPanelHeight, 0,
                       "the panel must start folded, not snap in")

        let deadline = Date().addingTimeInterval(5)
        while card.outputPanelHeight < fullHeight, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(card.outputPanelHeight, fullHeight,
                       "the unfold must settle at the same height an instant reveal gives")
        // The finish re-measure plus at least one animated step. A loaded machine may land
        // t ≥ 1 on the timer's first fire, so more steps than that cannot be demanded.
        XCTAssertGreaterThanOrEqual(host.heightChanges.count, 2,
                                    "the page must be re-measured by the reveal itself, "
                                        + "not only when the result arrives")
    }

    // MARK: What a console costs the page

    /// A settled console is measured once, not once per pass. Its transcript and the code text
    /// are read by every measure, layout, and draw the card takes while scrolling, and
    /// re-running TextKit on each of them is what made pages with consoles crawl.
    func testASettledConsoleDoesNotRemeasureItsTranscriptPerPass() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "make test", language: "bash",
                                     lines: lines("make test"), metrics: metrics, host: host)
        card.showRunOutput(ProcessRunner.Output(
            status: 0, outputText: (1...50).map { "line \($0)" }.joined(separator: "\n"),
            errorText: ""))
        card.frame = NSRect(x: 0, y: 0, width: width,
                            height: card.sizeThatFits(width: width).height)
        card.layoutSubtreeIfNeeded()
        _ = card.cardRect  // Warm every cache the passes below read.

        let before = TextMeasurer.shared.measures
        _ = card.sizeThatFits(width: width)
        _ = card.outputPanelHeight
        _ = card.cardRect
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(TextMeasurer.shared.measures, before,
                       "a settled console must serve measure, layout, and draw from cache")
    }

    /// A live output tick that leaves the console at the same height — every tick once it hits
    /// its cap — must not reflow the page. Reflowing detaches and reconfigures every visible
    /// view, and a chatty command reports twenty times a second for its whole run.
    func testAHeightNeutralRemeasureDoesNotReflowThePage() throws {
        let document = try makeDocument("""
        # T

        Some prose above the block.

        ```bash
        make test
        ```

        And some prose below it.
        """)
        let built = AttributedDocumentBuilder(document: document, metrics: metrics).build()
        let host = RecordingHost(metrics: metrics)
        let stack = DocumentStackView(metrics: metrics)
        stack.host = host
        stack.setComponents(built.components, metrics: metrics)
        stack.frame = NSRect(x: 0, y: 0, width: 600, height: 0)
        stack.columnWidth = 600
        stack.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(
            stack.subviews.compactMap { $0 as? CodeComponentView }.first)
        let button = try XCTUnwrap(card.runButton)
        click(button)
        // Past the cap: from here on, more output cannot change the console's height.
        host.emitOutput((1...200).map { "line \($0)" }.joined(separator: "\n"))
        stack.remeasureComponent(containing: card)
        XCTAssertTrue(stack.needsLayout, "the console appearing must reflow the page")
        stack.layoutSubtreeIfNeeded()

        host.emitOutput((1...220).map { "line \($0)" }.joined(separator: "\n"))
        stack.remeasureComponent(containing: card)
        XCTAssertFalse(stack.needsLayout,
                       "a capped console's output tick changes no geometry and must not "
                           + "reflow the page")

        // Closing the console is a real height change again.
        click(try XCTUnwrap(card.runPanel).closeButton)
        stack.remeasureComponent(containing: card)
        XCTAssertTrue(stack.needsLayout, "the console folding away must reflow the page")
    }

    /// A reflow moves the views around the console; it must not rebuild them. Retiring and
    /// reconfiguring every visible view — a full TextKit relayout of each — on every animation
    /// frame of an unfold is what kept scrolling janky around a run.
    func testAReflowMovesVisibleProseWithoutReconfiguringIt() throws {
        let document = try makeDocument("""
        # T

        First paragraph above the block.

        ```bash
        make test
        ```

        A paragraph below, which a growing console pushes down.

        And another one after it.
        """)
        let built = AttributedDocumentBuilder(document: document, metrics: metrics).build()
        let host = RecordingHost(metrics: metrics)
        let stack = DocumentStackView(metrics: metrics)
        stack.host = host
        stack.setComponents(built.components, metrics: metrics)
        stack.frame = NSRect(x: 0, y: 0, width: 600, height: 0)
        stack.columnWidth = 600
        stack.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(
            stack.subviews.compactMap { $0 as? CodeComponentView }.first)
        let proseBefore = stack.subviews.compactMap { $0 as? TextComponentView }
        XCTAssertGreaterThan(proseBefore.count, 1, "fixture needs prose around the block")

        click(try XCTUnwrap(card.runButton))
        host.emitOutput("hello\nworld")
        let configures = TextComponentView.configureCount
        stack.remeasureComponent(containing: card)
        stack.layoutSubtreeIfNeeded()

        XCTAssertEqual(TextComponentView.configureCount, configures,
                       "a reflow must reclaim the visible prose as it is, not rebuild it")
        let proseAfter = Set(stack.subviews.compactMap { $0 as? TextComponentView })
        for view in proseBefore {
            XCTAssertTrue(proseAfter.contains(view),
                          "the same view instances must survive the reflow")
        }
    }

    func testFailureOutputNamesTheExitStatus() {
        let text = RunOutputPanel.outputText(
            ProcessRunner.Output(status: 3, outputText: "out", errorText: "err"),
            metrics: metrics).string
        XCTAssertTrue(text.hasPrefix("exit 3"), "a failure must lead with its exit status")
        XCTAssertTrue(text.contains("out") && text.contains("err"))

        let silent = RunOutputPanel.outputText(
            ProcessRunner.Output(status: 0, outputText: "", errorText: ""),
            metrics: metrics).string
        XCTAssertEqual(silent, "(no output)",
                       "a silent success must not look like a dead button")
    }

    // MARK: End to end: the pane executes at the project root

    func testShellBlockExecutesAtTheProjectRoot() throws {
        let repo = scratch.appendingPathComponent("repo", isDirectory: true)
        let docs = repo.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let document = try makeDocument("# T\n\n```bash\npwd\n```\n", at: docs)

        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: document, metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<12 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        let card = try XCTUnwrap(
            view.stackView.subviews.compactMap { $0 as? CodeComponentView }.first)
        let button = try XCTUnwrap(card.runButton, "a bash card in the pane must be runnable")
        let heightBefore = card.frame.height

        click(button)
        let deadline = Date().addingTimeInterval(10)
        while card.runOutput == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        let result = try XCTUnwrap(card.runOutput, "the run never delivered its output")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(URL(fileURLWithPath: result.outputText).resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path,
                       "the block must run at the detected root, not the document's folder")
        XCTAssertTrue(button.isEnabled, "the button must re-enable after the run")

        // The panel shows inline: the stack re-measures the card and its frame grows.
        view.layoutSubtreeIfNeeded()
        for _ in 0..<12 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(card.frame.height, heightBefore,
                             "the page must make room for the output panel")
    }
}
