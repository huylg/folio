import AppKit
import XCTest
@testable import FolioKit

/// Running a shell block inside the hover peek card, end to end: the Run button in the card
/// executes at the previewed document's project root, the card grows downward around the
/// console, and — for the current document — the same console appears live on the block in the
/// reading pane, survives the card closing mid-run, and closes everywhere at once.
final class PeekRunTests: XCTestCase {

    private let metrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                          lineWidth: .comfortable, density: .airy)

    private var savedRevealDuration: TimeInterval = 0
    private var savedAppearDuration: TimeInterval = 0
    private var savedFadeOutDuration: TimeInterval = 0

    override func setUp() {
        super.setUp()
        // The machine's real pointer must not haunt the hover checks.
        PeekPreviewPanel.pointerLocation = { NSPoint(x: -100_000, y: -100_000) }
        TextComponentView.linkHoverDelay = 0.02
        savedRevealDuration = RunOutputPanel.revealDuration
        // Geometry assertions want settled states, not frames mid-unfold — and a full test
        // run's accumulated window animations can starve a real fade past any fixed wait.
        RunOutputPanel.revealDuration = 0
        savedAppearDuration = PeekPreviewPanel.appearDuration
        savedFadeOutDuration = PeekPreviewPanel.fadeOutDuration
        PeekPreviewPanel.appearDuration = 0
        PeekPreviewPanel.fadeOutDuration = 0
    }

    override func tearDown() {
        TextComponentView.linkHoverDelay = 0.4
        PeekPreviewPanel.pointerLocation = { NSEvent.mouseLocation }
        RunOutputPanel.revealDuration = savedRevealDuration
        PeekPreviewPanel.appearDuration = savedAppearDuration
        PeekPreviewPanel.fadeOutDuration = savedFadeOutDuration
        super.tearDown()
    }

    // MARK: Fixture

    /// A vault of its own, marked as a project root, whose document links to a section
    /// holding a runnable block.
    private func vault(gammaBlock: String, gammaParagraphs: Int = 1)
        throws -> (view: NativeDocumentView, window: NSWindow, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peek-run-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let body = (1...gammaParagraphs)
            .map { "Gamma body paragraph \($0)." }
            .joined(separator: "\n\n")
        let source = """
        Jump to [gamma](#gamma) below.

        ## Beta
        Beta body.

        ## Gamma
        \(body)

        ```bash
        \(gammaBlock)
        ```

        ## Omega
        """
        let url = root.appendingPathComponent("source.md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let document = try MarkdownDocument(url: url)

        let view = NativeDocumentView(metrics: metrics)
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: document, metrics: metrics)
        view.layoutSubtreeIfNeeded()
        return (view, window, root)
    }

    // MARK: Harness

    private func click(_ button: NSButton) {
        _ = button.target?.perform(button.action, with: button)
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }

    /// Rests the pointer on `destination`'s link and returns the presented card's window.
    private func hoverPeek(
        on destination: String, view: NativeDocumentView, window: NSWindow
    ) throws -> NSWindow {
        let text = try XCTUnwrap(
            view.stackView.subviews
                .compactMap { $0 as? TextComponentView }
                .first { $0.linkRectForTests(destination: destination) != nil },
            "the paragraph holding the link must be populated"
        )
        let rect = try XCTUnwrap(text.linkRectForTests(destination: destination))
        // Off the link first: a re-hover after a dismissal is a fresh gesture only once the
        // pointer has actually left — a pointer that never moved is still the old hover.
        text.hoverMoved(to: NSPoint(x: -1_000, y: -1_000))
        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertTrue(waitUntil { window.childWindows?.isEmpty == false },
                      "the hover must present the card")
        return try XCTUnwrap(window.childWindows?.first)
    }

    private func peekCodeCard(in cardWindow: NSWindow) throws -> CodeComponentView {
        let content = try XCTUnwrap(cardWindow.contentView)
        return try XCTUnwrap(first(CodeComponentView.self, in: content),
                             "the peeked section must show its code card")
    }

    private func mainCodeCard(in view: NativeDocumentView) throws -> CodeComponentView {
        try XCTUnwrap(
            view.stackView.subviews.compactMap { $0 as? CodeComponentView }.first,
            "the reading pane must have the block's card populated")
    }

    private func path(of output: ProcessRunner.Output) -> String {
        URL(fileURLWithPath: output.outputText).resolvingSymlinksInPath().path
    }

    // MARK: Tests

    func testRunInPeekExecutesAtTheProjectRootAndGrowsTheCardDownward() throws {
        let (view, window, root) = try vault(gammaBlock: "pwd")
        let cardWindow = try hoverPeek(on: "#gamma", view: view, window: window)
        let card = try peekCodeCard(in: cardWindow)
        let before = cardWindow.frame

        click(try XCTUnwrap(card.runButton, "a bash card in the peek must be runnable"))
        XCTAssertTrue(waitUntil { card.runOutput != nil }, "the run never delivered")

        let result = try XCTUnwrap(card.runOutput)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(path(of: result), root.resolvingSymlinksInPath().path,
                       "the block must run at the previewed document's project root")

        let after = cardWindow.frame
        XCTAssertGreaterThan(after.height, before.height,
                             "the console must grow the card")
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 1,
                       "the card grows downward — its top edge stays put")

        view.linkPeek.hide()
        waitUntil(2) { (window.childWindows ?? []).isEmpty }
    }

    func testACardAtTheHeightCapScrollsInsideInsteadOfGrowing() throws {
        // Enough section body that the console pushes the content past the card's height
        // cap — but only once the console is up, so the growth path crosses into overflow.
        let (view, window, _) = try vault(gammaBlock: "seq 1 100", gammaParagraphs: 8)
        let cardWindow = try hoverPeek(on: "#gamma", view: view, window: window)
        let card = try peekCodeCard(in: cardWindow)

        click(try XCTUnwrap(card.runButton))
        XCTAssertTrue(waitUntil { card.runOutput != nil }, "the run never delivered")
        spin(0.05)

        let cap = PeekPreviewPanel.headerHeight + PeekPreviewPanel.maxContentHeight
            + PeekPreviewPanel.padding * 2
        XCTAssertLessThanOrEqual(cardWindow.frame.height, cap,
                                 "the card must stop at its height cap")
        let content = try XCTUnwrap(cardWindow.contentView)
        let scroll = try XCTUnwrap(content.subviews.compactMap { $0 as? NSScrollView }
            .first { !$0.isHidden })
        let stack = try XCTUnwrap(scroll.documentView as? DocumentStackView)
        XCTAssertGreaterThan(stack.frame.height, scroll.contentSize.height,
                             "past the cap the content scrolls inside the card")

        view.linkPeek.hide()
        waitUntil(2) { (window.childWindows ?? []).isEmpty }
    }

    func testAPeekRunMirrorsOntoTheReadingPanesBlock() throws {
        let (view, window, root) = try vault(gammaBlock: "pwd")
        let cardWindow = try hoverPeek(on: "#gamma", view: view, window: window)
        let peekCard = try peekCodeCard(in: cardWindow)
        let mainCard = try mainCodeCard(in: view)
        XCTAssertTrue(peekCard !== mainCard)

        click(try XCTUnwrap(peekCard.runButton))
        XCTAssertEqual(mainCard.runPanels.count, 1,
                       "the run must open a console on the reading pane's block at once")
        XCTAssertTrue(mainCard.runPanels[0].isRunning)

        XCTAssertTrue(waitUntil { mainCard.runOutput != nil },
                      "the result must land on the reading pane's block")
        XCTAssertEqual(path(of: try XCTUnwrap(mainCard.runOutput)),
                       root.resolvingSymlinksInPath().path)
        XCTAssertEqual(peekCard.runOutput?.outputText, mainCard.runOutput?.outputText,
                       "both cards must show the same result")

        // Closing the console from the reading pane closes it in the card too — it is the
        // same run.
        click(mainCard.runPanels[0].closeButton)
        XCTAssertTrue(peekCard.runPanels.isEmpty,
                      "one close must fold the console on every surface")
        XCTAssertTrue(view.runSessions.sessions(for: peekCard.runKey).isEmpty)

        view.linkPeek.hide()
        waitUntil(2) { (window.childWindows ?? []).isEmpty }
    }

    func testClosingThePeekMidRunLetsTheRunFinishIntoTheReadingPane() throws {
        let (view, window, root) = try vault(gammaBlock: "sleep 0.3; pwd")
        let cardWindow = try hoverPeek(on: "#gamma", view: view, window: window)
        let peekCard = try peekCodeCard(in: cardWindow)
        let mainCard = try mainCodeCard(in: view)

        click(try XCTUnwrap(peekCard.runButton))
        XCTAssertTrue(mainCard.runPanels.first?.isRunning == true)

        // The reader moves on while the command is still running: the card goes, the run
        // does not.
        view.linkPeek.hide()
        XCTAssertTrue(waitUntil(2) { (window.childWindows ?? []).isEmpty })

        XCTAssertTrue(waitUntil { mainCard.runOutput != nil },
                      "the run must finish into the reading pane's console")
        XCTAssertEqual(path(of: try XCTUnwrap(mainCard.runOutput)),
                       root.resolvingSymlinksInPath().path)
    }

    /// A peek of *another* document runs at that document's own project root, and nothing of
    /// it lands in the pane's store or survives the card.
    func testACrossFilePeekRunsAtTheTargetsRootAndLeavesNothingBehind() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peek-run-vault-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        // The linked file lives in a project of its own: its runs must use *its* root.
        try FileManager.default.createDirectory(
            at: sub.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "# Notes\n\nOpening paragraph.\n\n```bash\npwd\n```\n"
            .write(to: sub.appendingPathComponent("Notes.md"),
                   atomically: true, encoding: .utf8)
        let sourceURL = root.appendingPathComponent("source.md")
        try "See [the notes](sub/Notes.md) in the vault.\n"
            .write(to: sourceURL, atomically: true, encoding: .utf8)

        let view = NativeDocumentView(metrics: metrics)
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try MarkdownDocument(url: sourceURL), metrics: metrics)
        view.layoutSubtreeIfNeeded()

        let cardWindow = try hoverPeek(on: "sub/Notes.md", view: view, window: window)
        let card = try peekCodeCard(in: cardWindow)
        click(try XCTUnwrap(card.runButton))
        XCTAssertTrue(waitUntil { card.runOutput != nil }, "the run never delivered")
        XCTAssertEqual(path(of: try XCTUnwrap(card.runOutput)),
                       sub.resolvingSymlinksInPath().path,
                       "a cross-file peek must run at the target's root, not the pane's")
        XCTAssertTrue(view.runSessions.sessions(for: card.runKey).isEmpty,
                      "a cross-file run must not land in the pane's store")

        view.linkPeek.hide()
        XCTAssertTrue(waitUntil(2) { (window.childWindows ?? []).isEmpty })

        // Peeked again, the block starts clean: nothing persisted with the throwaway store.
        let again = try hoverPeek(on: "sub/Notes.md", view: view, window: window)
        XCTAssertTrue(try peekCodeCard(in: again).runPanels.isEmpty,
                      "a cross-file peek's consoles must not outlive the card")
        view.linkPeek.hide()
        waitUntil(2) { (window.childWindows ?? []).isEmpty }
    }

    /// The deliberate behavior change that comes with sessions: a console now survives a
    /// re-render of the same document — the fresh card adopts it back.
    func testConsolesSurviveARerenderOfTheSameDocument() throws {
        let (view, _, root) = try vault(gammaBlock: "pwd")
        let card = try mainCodeCard(in: view)
        click(try XCTUnwrap(card.runButton))
        XCTAssertTrue(waitUntil { card.runOutput != nil }, "the run never delivered")
        let output = try XCTUnwrap(card.runOutput)

        let document = try MarkdownDocument(url: root.appendingPathComponent("source.md"))
        view.render(document: document, metrics: metrics)
        view.layoutSubtreeIfNeeded()

        let fresh = try mainCodeCard(in: view)
        XCTAssertTrue(fresh !== card, "the re-render must have made a new card")
        XCTAssertEqual(fresh.runEntries.count, 1,
                       "the fresh card must adopt the surviving console")
        XCTAssertEqual(fresh.runOutput?.outputText, output.outputText)
    }
}
