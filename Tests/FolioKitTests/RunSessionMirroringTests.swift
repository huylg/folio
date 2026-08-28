import AppKit
import XCTest
@testable import FolioKit

/// A run's state lives in a `RunSession`, shared through a `RunSessionStore`: two views bound
/// to the same block key — the reading pane's card and a peek card showing the same block —
/// render the same consoles, live, and closing one closes it everywhere.
final class RunSessionMirroringTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )
    private let width: CGFloat = 500

    private var savedRevealDuration: TimeInterval = 0

    override func setUp() {
        super.setUp()
        savedRevealDuration = RunOutputPanel.revealDuration
        RunOutputPanel.revealDuration = 0
    }

    override func tearDown() {
        RunOutputPanel.revealDuration = savedRevealDuration
        super.tearDown()
    }

    private func lines(_ code: String) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [.font: metrics.ramp.mono()])
    }

    private func click(_ button: NSButton) {
        _ = button.target?.perform(button.action, with: button)
    }

    private let key = RunBlockKey(
        documentURL: URL(fileURLWithPath: "/tmp/mirror-doc.md"), location: 42
    )

    private func boundCard(host: RecordingHost, store: RunSessionStore) -> CodeComponentView {
        let card = CodeComponentView(label: "bash", source: "echo hi", language: "bash",
                                     lines: lines("echo hi"), metrics: metrics, host: host)
        card.bindRunSessions(key: key, store: store)
        return card
    }

    func testRunStartedInOneViewOpensAConsoleInBoth() throws {
        let store = RunSessionStore()
        let hostA = RecordingHost()
        let hostB = RecordingHost()
        let a = boundCard(host: hostA, store: store)
        let b = boundCard(host: hostB, store: store)

        click(try XCTUnwrap(a.runButton))
        XCTAssertEqual(hostA.ran, ["echo hi"], "the clicked view's host executes")
        XCTAssertTrue(hostB.ran.isEmpty, "the mirroring view must not execute a second time")
        let inA = try XCTUnwrap(a.runPanel)
        let inB = try XCTUnwrap(b.runPanel,
                                "the same run must open a console in every bound view")
        XCTAssertTrue(inA.isRunning)
        XCTAssertTrue(inB.isRunning)
        XCTAssertTrue(inA.session === inB.session,
                      "both consoles must render the same session")
        XCTAssertFalse(try XCTUnwrap(b.runButton).isEnabled,
                       "the mirroring view's button goes out with the run")
    }

    func testLiveTranscriptFlowsToEveryBoundView() throws {
        let store = RunSessionStore()
        let hostA = RecordingHost()
        let a = boundCard(host: hostA, store: store)
        let b = boundCard(host: RecordingHost(), store: store)

        click(try XCTUnwrap(a.runButton))
        let inA = try XCTUnwrap(a.runPanel)
        let inB = try XCTUnwrap(b.runPanel)
        let empty = inB.fullHeight
        hostA.emitOutput("hello\nworld\n")

        XCTAssertEqual(inA.liveTranscript.plainText, "hello\nworld\n")
        XCTAssertEqual(inB.liveTranscript.plainText, "hello\nworld\n",
                       "live output must reach the view that did not start the run")
        XCTAssertEqual(inA.fullHeight, inB.fullHeight,
                       "both consoles must measure alike")
        XCTAssertEqual(inB.fullHeight, empty,
                       "and output must not resize either of them")
    }

    func testFinishLandsInBoth() throws {
        let store = RunSessionStore()
        let hostA = RecordingHost()
        let a = boundCard(host: hostA, store: store)
        let b = boundCard(host: RecordingHost(), store: store)

        click(try XCTUnwrap(a.runButton))
        hostA.finishPendingRuns(with: ProcessRunner.Output(status: 0, outputText: "done",
                                                           errorText: ""))
        XCTAssertEqual(a.runOutput?.outputText, "done")
        XCTAssertEqual(b.runOutput?.outputText, "done",
                       "the result must land in every bound view")
        XCTAssertFalse(try XCTUnwrap(a.runPanel).isRunning)
        XCTAssertFalse(try XCTUnwrap(b.runPanel).isRunning)
    }

    func testCloseInOneClosesEverywhere() throws {
        let store = RunSessionStore()
        let a = boundCard(host: RecordingHost(), store: store)
        let b = boundCard(host: RecordingHost(), store: store)

        a.showRunOutput(ProcessRunner.Output(status: 0, outputText: "x", errorText: ""))
        XCTAssertNotNil(a.runPanel)
        let inB = try XCTUnwrap(b.runPanel)

        click(inB.closeButton)
        XCTAssertNil(a.runPanel,
                     "closing a console in one view must close it in the other")
        XCTAssertNil(b.runPanel)
        XCTAssertNil(store.session(for: key), "a closed session must leave the store")
    }

    func testLateBindAdoptsSessionsWithoutUnfoldAnimation() throws {
        let store = RunSessionStore()
        let a = boundCard(host: RecordingHost(), store: store)
        a.showRunOutput(ProcessRunner.Output(status: 0, outputText: "earlier", errorText: ""))

        // A view created after the run — a card scrolled into view, a peek of a block that
        // already ran — shows the console settled, without waiting out an unfold.
        RunOutputPanel.revealDuration = 0.25
        let host = RecordingHost()
        let late = boundCard(host: host, store: store)
        XCTAssertNotNil(late.runPanel)
        XCTAssertGreaterThan(late.outputPanelHeight, 0,
                             "an adopted console must arrive already revealed")
        XCTAssertEqual(late.outputPanelHeight, a.outputPanelHeight,
                       "and it must measure exactly like the settled original")
        XCTAssertEqual(host.heightChanges.count, 1,
                       "adoption must tell the host once, so the page makes room")
    }

    /// One block, one console — on every surface. A re-run in one view replaces the console
    /// in the other too, rather than leaving it showing a result that is no longer the
    /// block's.
    func testARerunReplacesTheConsoleInEveryBoundView() throws {
        let store = RunSessionStore()
        let a = boundCard(host: RecordingHost(), store: store)
        let b = boundCard(host: RecordingHost(), store: store)

        for run in 1...4 {
            a.showRunOutput(ProcessRunner.Output(status: 0, outputText: "run \(run)",
                                                 errorText: ""))
        }
        XCTAssertEqual(a.subviews.compactMap { $0 as? RunOutputPanel }.count, 1)
        XCTAssertEqual(b.subviews.compactMap { $0 as? RunOutputPanel }.count, 1,
                       "one console per block, on every surface")
        XCTAssertEqual(a.runOutput?.outputText, "run 4")
        XCTAssertEqual(b.runOutput?.outputText, "run 4",
                       "the mirroring view must show the latest run, not an older one")
        XCTAssertTrue(a.runPanel?.session === store.session(for: key))
        XCTAssertTrue(b.runPanel?.session === store.session(for: key))
    }

    /// Runs are serial across the whole store: a second block cannot start while the first is
    /// still going, whichever surface asks.
    func testTheStoreRefusesASecondRunWhileOneIsInFlight() throws {
        let store = RunSessionStore()
        let other = RunBlockKey(documentURL: key.documentURL, location: key.location + 100)

        let running = try XCTUnwrap(store.begin(key: key))
        XCTAssertTrue(store.isRunning)
        XCTAssertNil(store.begin(key: other), "a second block must not run in parallel")
        XCTAssertNil(store.begin(key: key), "nor may the same block run twice at once")
        XCTAssertTrue(store.session(for: key) === running,
                      "the refused run must leave the live one alone")

        running.finish(with: ProcessRunner.Output(status: 0, outputText: "done", errorText: ""))
        XCTAssertFalse(store.isRunning, "a finished run no longer holds the gate")
        XCTAssertNotNil(store.begin(key: other))
    }

    /// A session begun for a block whose card has never been created — a run started from a
    /// peek for a block the reader has not scrolled to — must still reserve its space in the
    /// page's measure, through the store fallback.
    func testMeasureIncludesSessionForNeverPopulatedView() {
        let store = RunSessionStore()
        let documentURL = URL(fileURLWithPath: "/tmp/mirror-doc.md")
        let source = "echo hi"
        let component = DocumentComponent(
            kind: .codeHeader,
            content: .code(label: "bash", source: source, language: "bash",
                           lines: lines(source)),
            range: NSRange(location: 42, length: source.count)
        )

        let host = RecordingHost(metrics: metrics)
        let stack = DocumentStackView(metrics: metrics)
        stack.host = host
        stack.runContext = RunContext(documentURL: documentURL,
                                      rootURL: documentURL.deletingLastPathComponent(),
                                      store: store)
        stack.columnWidth = width
        stack.setComponents([component], metrics: metrics)
        // Measured only — never populated, so no CodeComponentView exists to answer for the
        // consoles.
        stack.ensureMeasured()
        let bare = stack.contentHeight

        store.begin(key: RunBlockKey(documentURL: documentURL, location: 42))?
            .finish(with: ProcessRunner.Output(status: 0, outputText: "line\nline",
                                               errorText: ""))
        stack.remeasureComponent(at: 0)
        stack.ensureMeasured()

        let expected = store.consoleHeight(
            for: RunBlockKey(documentURL: documentURL, location: 42), metrics: metrics)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(stack.contentHeight, bare + expected,
                       "the page must make room for a console no view has drawn yet")
    }
}
