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
        XCTAssertEqual(a.runPanels.count, 1)
        XCTAssertEqual(b.runPanels.count, 1,
                       "the same run must open a console in every bound view")
        XCTAssertTrue(a.runPanels[0].isRunning)
        XCTAssertTrue(b.runPanels[0].isRunning)
        XCTAssertTrue(a.runPanels[0].session === b.runPanels[0].session,
                      "both consoles must render the same session")
    }

    func testLiveTranscriptFlowsToEveryBoundView() throws {
        let store = RunSessionStore()
        let hostA = RecordingHost()
        let a = boundCard(host: hostA, store: store)
        let b = boundCard(host: RecordingHost(), store: store)

        click(try XCTUnwrap(a.runButton))
        let empty = b.runPanels[0].fullHeight(width: width)
        hostA.emitOutput("hello\nworld\n")

        XCTAssertEqual(a.runPanels[0].liveTranscript, "hello\nworld\n")
        XCTAssertEqual(b.runPanels[0].liveTranscript, "hello\nworld\n",
                       "live output must reach the view that did not start the run")
        XCTAssertEqual(a.runPanels[0].fullHeight(width: width),
                       b.runPanels[0].fullHeight(width: width),
                       "both consoles must measure the same transcript alike")
        XCTAssertGreaterThan(b.runPanels[0].fullHeight(width: width), empty)
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
        XCTAssertFalse(a.runPanels[0].isRunning)
        XCTAssertFalse(b.runPanels[0].isRunning)
    }

    func testCloseInOneClosesEverywhere() throws {
        let store = RunSessionStore()
        let a = boundCard(host: RecordingHost(), store: store)
        let b = boundCard(host: RecordingHost(), store: store)

        a.showRunOutput(ProcessRunner.Output(status: 0, outputText: "x", errorText: ""))
        XCTAssertEqual(a.runPanels.count, 1)
        XCTAssertEqual(b.runPanels.count, 1)

        click(b.runPanels[0].closeButton)
        XCTAssertTrue(a.runPanels.isEmpty,
                      "closing a console in one view must close it in the other")
        XCTAssertTrue(b.runPanels.isEmpty)
        XCTAssertTrue(store.sessions(for: key).isEmpty,
                      "a closed session must leave the store")
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
        XCTAssertEqual(late.runPanels.count, 1)
        XCTAssertGreaterThan(late.outputPanelHeight(width: width), 0,
                             "an adopted console must arrive already revealed")
        XCTAssertEqual(late.outputPanelHeight(width: width),
                       a.outputPanelHeight(width: width),
                       "and it must measure exactly like the settled original")
        XCTAssertEqual(host.heightChanges.count, 1,
                       "adoption must tell the host once, so the page makes room")
    }

    func testSharedHistoryCapDropsOldestEverywhere() throws {
        let store = RunSessionStore()
        let a = boundCard(host: RecordingHost(), store: store)
        let b = boundCard(host: RecordingHost(), store: store)

        for run in 1...(RunSessionStore.maxRunHistory + 3) {
            a.showRunOutput(ProcessRunner.Output(status: 0, outputText: "run \(run)",
                                                 errorText: ""))
        }
        XCTAssertEqual(a.runPanels.count, RunSessionStore.maxRunHistory)
        XCTAssertEqual(b.runPanels.count, RunSessionStore.maxRunHistory,
                       "the cap is the store's, so every view agrees")
        XCTAssertEqual(b.runOutput?.outputText,
                       "run \(RunSessionStore.maxRunHistory + 3)",
                       "the cap must drop the oldest runs, never the newest")
        XCTAssertEqual(store.sessions(for: key).count, RunSessionStore.maxRunHistory)
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

        store.begin(key: RunBlockKey(documentURL: documentURL, location: 42))
            .finish(with: ProcessRunner.Output(status: 0, outputText: "line\nline",
                                               errorText: ""))
        stack.remeasureComponent(at: 0)
        stack.ensureMeasured()

        let expected = store.consoleHeight(
            for: RunBlockKey(documentURL: documentURL, location: 42),
            width: width, metrics: metrics)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(stack.contentHeight, bare + expected,
                       "the page must make room for a console no view has drawn yet")
    }
}
