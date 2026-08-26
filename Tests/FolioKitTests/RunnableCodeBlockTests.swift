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
        savedRevealDuration = CodeComponentView.outputRevealDuration
        CodeComponentView.outputRevealDuration = 0
    }

    override func tearDownWithError() throws {
        CodeComponentView.outputRevealDuration = savedRevealDuration
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

    func testRunOpensARunningConsoleWithoutBlockingTheButton() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "echo hi", language: "bash",
                                     lines: lines("echo hi"), metrics: metrics, host: host)
        let button = try XCTUnwrap(card.runButton)

        click(button)
        XCTAssertEqual(host.ran, ["echo hi"])
        XCTAssertTrue(button.isEnabled, "the run must never block the button")
        XCTAssertEqual(card.runPanels.count, 1,
                       "a console must appear the moment the run starts")
        XCTAssertTrue(card.runPanels[0].isRunning)
        XCTAssertNil(card.runOutput, "no result yet — the command is still running")
        XCTAssertGreaterThan(card.outputPanelHeight(width: width), 0,
                             "the running console must already take space on the page")

        // The pty streams into the running console as the command produces output.
        let emptyHeight = card.runPanels[0].fullHeight(width: width)
        host.emitOutput("hello\nworld\nagain\n")
        XCTAssertEqual(card.runPanels[0].liveTranscript, "hello\nworld\nagain\n",
                       "live output must land in the console before the command exits")
        XCTAssertTrue(card.runPanels[0].isRunning)
        XCTAssertGreaterThan(card.runPanels[0].fullHeight(width: width), emptyHeight,
                             "the console must grow with the live output")

        // A second click mid-run opens a second console instead of being swallowed.
        click(button)
        XCTAssertEqual(host.ran, ["echo hi", "echo hi"])
        XCTAssertEqual(card.runPanels.count, 2)

        host.finishPendingRuns(with: ProcessRunner.Output(status: 0, outputText: "hi",
                                                          errorText: ""))
        XCTAssertEqual(card.runPanels.filter(\.isRunning).count, 0,
                       "both consoles must carry their run to completion")
        XCTAssertEqual(card.runEntries.count, 2)
    }

    func testClosingARunningConsoleDiscardsItsLateResult() throws {
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "sleep 5", language: "bash",
                                     lines: lines("sleep 5"), metrics: metrics, host: host)

        click(try XCTUnwrap(card.runButton))
        XCTAssertEqual(card.runPanels.count, 1)

        // The reader gives up on it before it exits.
        click(card.runPanels[0].closeButton)
        XCTAssertTrue(card.runPanels.isEmpty)

        // The command exits later — its console is gone, so the result goes nowhere.
        host.finishPendingRuns(with: ProcessRunner.Output(status: 0, outputText: "late",
                                                          errorText: ""))
        XCTAssertTrue(card.runPanels.isEmpty)
        XCTAssertNil(card.runOutput)
    }

    func testOutputGrowsTheCardAndDismissalShrinksItBack() throws {
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
        XCTAssertGreaterThan(card.sizeThatFits(width: width).height, running,
                             "the result must grow the console past its running state")
        XCTAssertGreaterThan(host.heightChanges.count, 0,
                             "the card must ask its host to re-measure it")

        // The console's own close button folds it away and re-measures again.
        let close = try XCTUnwrap(buttons(under: card).first { $0.toolTip == "Close result" })
        click(close)
        XCTAssertNil(card.runOutput)
        XCTAssertEqual(card.sizeThatFits(width: width).height, bare,
                       "closing must restore the bare height")
    }

    func testLongOutputIsCappedNotUnbounded() {
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "yes", language: "bash",
                                     lines: lines("yes"), metrics: metrics, host: host)
        let chatty = (1...500).map { "line \($0)" }.joined(separator: "\n")
        card.showRunOutput(ProcessRunner.Output(status: 0, outputText: chatty, errorText: ""))
        XCTAssertLessThanOrEqual(
            card.outputPanelHeight(width: 500),
            CodeComponentView.maxOutputTextHeight + CardChrome.headerHeight + 60,
            "a chatty command must scroll inside the console, not take over the page")
    }

    func testEveryRunGetsItsOwnConsoleNewestOnTop() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "date", language: "bash",
                                     lines: lines("date"), metrics: metrics, host: host)
        card.frame = NSRect(x: 0, y: 0, width: width, height: 0)

        card.showRunOutput(ProcessRunner.Output(status: 0, outputText: "first run",
                                                errorText: ""))
        let single = card.outputPanelHeight(width: width)

        card.showRunOutput(ProcessRunner.Output(status: 0, outputText: "second run",
                                                errorText: ""))
        XCTAssertEqual(card.runPanels.count, 2,
                       "every run must get a console of its own")
        XCTAssertEqual(card.runOutput?.outputText, "second run",
                       "the newest console must be the one on top")
        XCTAssertGreaterThan(card.outputPanelHeight(width: width), single,
                             "a second console must grow the card further")

        card.frame = NSRect(x: 0, y: 0, width: width,
                            height: card.sizeThatFits(width: width).height)
        card.layoutSubtreeIfNeeded()
        XCTAssertLessThan(card.runPanels[0].frame.minY, card.runPanels[1].frame.minY,
                          "the latest console must sit above the previous one")

        // Closing one specific console keeps the other.
        let older = card.runPanels[1]
        XCTAssertEqual(older.entry?.output.outputText, "first run")
        click(older.closeButton)
        XCTAssertEqual(card.runEntries.map(\.output.outputText), ["second run"],
                       "closing the older console must leave the newer one alone")
        XCTAssertEqual(card.outputPanelHeight(width: width), single,
                       "one remaining console must measure like a single run")

        click(card.runPanels[0].closeButton)
        XCTAssertTrue(card.runPanels.isEmpty)
        XCTAssertNil(card.runOutput)
    }

    func testTheHistoryIsCapped() {
        let card = CodeComponentView(label: "bash", source: "x", language: "bash",
                                     lines: lines("x"), metrics: metrics,
                                     host: RecordingHost())
        for run in 1...(CodeComponentView.maxRunHistory + 3) {
            card.showRunOutput(ProcessRunner.Output(status: 0, outputText: "run \(run)",
                                                    errorText: ""))
        }
        XCTAssertEqual(card.runEntries.count, CodeComponentView.maxRunHistory)
        XCTAssertEqual(card.runOutput?.outputText,
                       "run \(CodeComponentView.maxRunHistory + 3)",
                       "the cap must drop the oldest runs, never the newest")
    }

    func testTheCappedViewportShowsWholeLinesOnly() throws {
        let width: CGFloat = 500
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "make test", language: "bash",
                                     lines: lines("make test"), metrics: metrics, host: host)
        click(try XCTUnwrap(card.runButton))
        host.emitOutput((1...200).map { "line \($0)" }.joined(separator: "\n"))

        let panel = try XCTUnwrap(card.runPanels.first)
        let insets = metrics.codeCardInsets
        let body = panel.fullHeight(width: width)
            - CardChrome.headerHeight - insets.bodyTop - insets.bodyBottom
        let line = TextComponentView.height(
            of: RunOutputPanel.liveText("x", metrics: metrics), width: 1000)
        XCTAssertLessThanOrEqual(body, CodeComponentView.maxOutputTextHeight)
        XCTAssertEqual(body.truncatingRemainder(dividingBy: line), 0,
                       "a viewport of 13½ lines shows half a string at its edge")
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

        let panel = try XCTUnwrap(card.runPanels.first)
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

        let panel = try XCTUnwrap(card.runPanels.first)
        let line = TextComponentView.height(
            of: RunOutputPanel.liveText("x", metrics: metrics), width: 1000)
        let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThan(text.frame.height, line * 2,
                          "one long line must stay one line, not wrap into a paragraph")
        XCTAssertGreaterThan(text.frame.width, scroll.contentView.bounds.width,
                             "the long line must extend into a horizontal scroll")
    }

    /// The horizontal scroll bar is carved out of the viewport, so the viewport must reserve
    /// room for it — or two lines of output end up needing a vertical scroll bar.
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

        let panel = try XCTUnwrap(card.runPanels.first)
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
        let fullHeight = settled.outputPanelHeight(width: width)
        XCTAssertGreaterThan(fullHeight, 0)

        CodeComponentView.outputRevealDuration = 0.25
        let host = RecordingHost()
        let card = CodeComponentView(label: "bash", source: "x", language: "bash",
                                     lines: lines("x"), metrics: metrics, host: host)
        card.showRunOutput(result)
        XCTAssertEqual(card.outputPanelHeight(width: width), 0,
                       "the panel must start folded, not snap in")

        let deadline = Date().addingTimeInterval(5)
        while card.outputPanelHeight(width: width) < fullHeight, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(card.outputPanelHeight(width: width), fullHeight,
                       "the unfold must settle at the same height an instant reveal gives")
        // The finish re-measure plus at least one animated step. A loaded machine may land
        // t ≥ 1 on the timer's first fire, so more steps than that cannot be demanded.
        XCTAssertGreaterThanOrEqual(host.heightChanges.count, 2,
                                    "the page must be re-measured by the reveal itself, "
                                        + "not only when the result arrives")
    }

    func testFailureOutputNamesTheExitStatus() {
        let text = CodeComponentView.outputText(
            ProcessRunner.Output(status: 3, outputText: "out", errorText: "err"),
            metrics: metrics).string
        XCTAssertTrue(text.hasPrefix("exit 3"), "a failure must lead with its exit status")
        XCTAssertTrue(text.contains("out") && text.contains("err"))

        let silent = CodeComponentView.outputText(
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
