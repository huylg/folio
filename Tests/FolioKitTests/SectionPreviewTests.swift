import AppKit
import WebKit
import XCTest
@testable import FolioKit

/// Parses markdown source through the real document pipeline via a temp file — the package's
/// only entry point is `MarkdownDocument(url:)`.
private func makeDocument(_ source: String) throws -> MarkdownDocument {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("section-preview-\(UUID().uuidString).md")
    try source.write(to: url, atomically: true, encoding: .utf8)
    return try MarkdownDocument(url: url)
}

private let previewTestMetrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                          lineWidth: .comfortable, density: .airy)

private func build(_ document: MarkdownDocument) -> BuiltDocument {
    AttributedDocumentBuilder(document: document, metrics: previewTestMetrics).build()
}

/// A one-paragraph section preview, for gesture tests that don't care about the content.
private func textPreview(_ string: String) -> SectionPreview {
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.labelColor,
    ])
    let component = DocumentComponent(
        kind: .paragraph, content: .text(attributed),
        range: NSRange(location: 0, length: (string as NSString).length)
    )
    return SectionPreview(components: [component], metrics: previewTestMetrics)
}

/// No leading H1 on purpose, so the synthesized title stays out of `headings` and the outline
/// indices are unambiguous: Beta 0, Gamma 1, Delta 2, Omega 3.
private let fixtureSource = """
Intro paragraph before any heading.

## Beta
Second paragraph.

| a | b |
|---|---|
| 1 | 2 |

## Gamma
### Delta
Deep text under Delta.

## Omega
"""

final class SectionExtentTests: XCTestCase {

    func testSectionEndsAtNextHeadingOfSameLevel() throws {
        let built = build(try makeDocument(fixtureSource))
        let beta = try XCTUnwrap(built.sectionRange(forOutlineIndex: 0))
        XCTAssertEqual(beta.location, built.headings[0].range.location)
        XCTAssertEqual(NSMaxRange(beta), built.headings[1].range.location,
                       "Beta's section must stop where Gamma begins")
    }

    func testDeeperHeadingIsClosedByShallowerOne() throws {
        let built = build(try makeDocument(fixtureSource))
        // Delta is an H3 followed by an H2: the rule is level <=, not ==.
        let delta = try XCTUnwrap(built.sectionRange(forOutlineIndex: 2))
        XCTAssertEqual(NSMaxRange(delta), built.headings[3].range.location,
                       "an H2 must close an H3's section")
    }

    func testShallowSectionSpansItsSubsections() throws {
        let built = build(try makeDocument(fixtureSource))
        // Gamma is an H2 whose only content is the H3 subsection: the subsection is inside it.
        let gamma = try XCTUnwrap(built.sectionRange(forOutlineIndex: 1))
        XCTAssertEqual(NSMaxRange(gamma), built.headings[3].range.location,
                       "Gamma's section must run through Delta to Omega")
    }

    func testLastSectionRunsToEndOfDocument() throws {
        let built = build(try makeDocument(fixtureSource))
        let omega = try XCTUnwrap(built.sectionRange(forOutlineIndex: 3))
        XCTAssertEqual(NSMaxRange(omega), built.attributed.length)
    }

    func testOutOfRangeIndexReturnsNil() throws {
        let built = build(try makeDocument(fixtureSource))
        XCTAssertNil(built.sectionRange(forOutlineIndex: -1))
        XCTAssertNil(built.sectionRange(forOutlineIndex: built.headings.count))
    }
}

final class SectionPreviewTests: XCTestCase {

    override func tearDown() {
        SectionPreviewBuilder.componentLimit = 24
        SectionPreviewBuilder.characterLimit = 6000
        super.tearDown()
    }

    func testHeadingItselfIsSkipped() throws {
        let built = build(try makeDocument(fixtureSource))
        let components = SectionPreviewBuilder.components(forOutlineIndex: 0, in: built)
        XCTAssertFalse(components.isEmpty)
        XCTAssertFalse(components.contains { $0.range == built.headings[0].range },
                       "the row already shows the title; the card must not repeat it")
        XCTAssertTrue(components.contains { $0.copyText.contains("Second paragraph") })
    }

    func testWidgetArrivesAsItsRealComponent() throws {
        let built = build(try makeDocument(fixtureSource))
        let components = SectionPreviewBuilder.components(forOutlineIndex: 0, in: built)
        let table = components.first {
            if case .widget(.table) = $0.content { return true } else { return false }
        }
        guard case .widget(.table(let spec))? = table?.content else {
            return XCTFail("the table must reach the card as the table component, "
                           + "not a placeholder line")
        }
        XCTAssertEqual(spec.columnCount, 2, "and it must be the document's own table")
    }

    func testEmptySectionReturnsNothing() throws {
        let built = build(try makeDocument(fixtureSource))
        XCTAssertTrue(SectionPreviewBuilder.components(forOutlineIndex: 3, in: built).isEmpty,
                      "Omega has nothing under its heading; a blank card must not be presented")
    }

    func testComponentLimitCapsThePreview() throws {
        let built = build(try makeDocument(fixtureSource))
        SectionPreviewBuilder.componentLimit = 1
        let components = SectionPreviewBuilder.components(forOutlineIndex: 0, in: built)
        XCTAssertEqual(components.count, 1)
        XCTAssertTrue(components[0].copyText.contains("Second paragraph"),
                      "the cap keeps the front of the section, not an arbitrary slice")
    }

    func testCharacterLimitCapsThePreview() throws {
        let built = build(try makeDocument(fixtureSource))
        SectionPreviewBuilder.characterLimit = 1
        let components = SectionPreviewBuilder.components(forOutlineIndex: 0, in: built)
        XCTAssertEqual(components.count, 1, "the slice ends once the cap is crossed")
    }
}

/// The whole gesture, driven through synthesized events against a real outline in a real
/// window: press → hold → card and dimmed backdrop appear; release → both stay; a click on
/// the backdrop → both go away.
final class OutlinePressIntegrationTests: XCTestCase {

    override func tearDown() {
        OutlineTableView.holdDelay = 0.35
        super.tearDown()
    }

    private func outline() throws -> (OutlineViewController, OutlineTableView, NSWindow) {
        let controller = OutlineViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        let window = TestWindow(contentRect: controller.view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderBack(nil)
        controller.update(document: try makeDocument(fixtureSource))
        controller.onPreviewContent = { _ in textPreview("Preview body") }
        controller.view.layoutSubtreeIfNeeded()

        guard let table = (controller.view.subviews.first as? NSScrollView)?
            .documentView as? OutlineTableView
        else { throw XCTSkip("no table") }
        return (controller, table, window)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins the run loop until `condition` holds, or the timeout passes. Fixed spins sized
    /// on a fast machine starve the hold timer on a loaded CI runner; a condition cannot.
    @discardableResult
    private func waitUntil(
        _ timeout: TimeInterval = 2, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testHoldShowsCardReleasePinsItAndBackdropClickDismisses() throws {
        OutlineTableView.holdDelay = 0.02
        let (controller, table, window) = try outline()
        let rowPoint = table.convert(
            NSPoint(x: table.rect(ofRow: 1).midX, y: table.rect(ofRow: 1).midY), to: nil
        )

        table.mouseDown(with: try mouseEvent(.leftMouseDown, at: rowPoint, in: window))
        XCTAssertTrue(waitUntil { window.childWindows?.isEmpty == false },
                      "the hold must present the card")
        let overlays = window.contentView?.subviews.count ?? 0
        XCTAssertGreaterThan(overlays, 1, "the backdrop must dim while the card is up")

        table.mouseUp(with: try mouseEvent(.leftMouseUp, at: rowPoint, in: window))
        spin(0.02)
        XCTAssertEqual(window.childWindows?.count, 1, "release must keep the card up")

        // The layer under the card is dimmed and inert: pointer feedback in the sidebar must
        // stay silent while the card is pinned.
        XCTAssertTrue(table.hoverSuppressed, "hover must be suppressed while the card is up")
        table.refreshHover()
        XCTAssertEqual(table.hoveredRow, -1, "no row may answer the pointer under the backdrop")

        // The dimming overlay is the topmost content subview; a click landing on it — anywhere
        // outside the card — closes the peek and goes no further.
        let outside = try mouseEvent(.leftMouseDown, at: NSPoint(x: 5, y: 5), in: window)
        window.contentView?.hitTest(NSPoint(x: 5, y: 5))?.mouseDown(with: outside)
        XCTAssertTrue(waitUntil { (window.childWindows ?? []).isEmpty },
                      "a click outside the card must dismiss it")
        XCTAssertEqual(window.contentView?.subviews.count, overlays - 1,
                       "the backdrop must go away with the card")
        XCTAssertFalse(table.hoverSuppressed, "hover must come back once the card is gone")
        _ = controller // kept alive for the duration of the gesture
    }

    func testLongContentScrollsInsideTheCard() throws {
        OutlineTableView.holdDelay = 0.02
        let (controller, table, window) = try outline()
        controller.onPreviewContent = { _ in
            textPreview(Array(repeating: "A line of preview text.", count: 200)
                .joined(separator: "\n"))
        }
        let rowPoint = table.convert(
            NSPoint(x: table.rect(ofRow: 1).midX, y: table.rect(ofRow: 1).midY), to: nil
        )
        table.mouseDown(with: try mouseEvent(.leftMouseDown, at: rowPoint, in: window))
        XCTAssertTrue(waitUntil { window.childWindows?.isEmpty == false },
                      "the hold must present the card")

        let card = try XCTUnwrap(window.childWindows?.first?.contentView)
        let scroll = try XCTUnwrap(card.subviews.compactMap { $0 as? NSScrollView }.first,
                                   "the card's content must live in a scroll view")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height,
                             "long content must overflow the card and be scrollable")
        XCTAssertLessThanOrEqual(
            document.frame.width, scroll.contentSize.width - PeekPreviewPanel.scrollerGutter,
            "scrolling content must step back from under the overlay scroller"
        )

        // Scroll to the end: everything must be reachable, and the "more below" fade must go.
        scroll.contentView.scroll(to: NSPoint(
            x: 0, y: document.frame.height - scroll.contentSize.height
        ))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThanOrEqual(
            scroll.contentView.bounds.maxY, document.frame.height - 1,
            "the bottom of the content must be reachable by scrolling"
        )

        table.mouseUp(with: try mouseEvent(.leftMouseUp, at: rowPoint, in: window))
        controller.cancelPreview()
        waitUntil { (window.childWindows ?? []).isEmpty }
    }

    /// The point of the engine reuse: a section holding a table, previewed end-to-end, must
    /// draw that table with the reading pane's own `TableBlockView` inside a
    /// `DocumentStackView` — not a text substitute.
    func testCardRendersBlocksWithTheReadingEngine() throws {
        OutlineTableView.holdDelay = 0.02
        let (controller, table, window) = try outline()
        let built = build(try makeDocument(fixtureSource))
        controller.onPreviewContent = { index in
            let components = SectionPreviewBuilder.components(forOutlineIndex: index, in: built)
            guard !components.isEmpty else { return nil }
            return SectionPreview(components: components, metrics: previewTestMetrics)
        }

        // Row 0 is Beta: a paragraph and a table.
        let rowPoint = table.convert(
            NSPoint(x: table.rect(ofRow: 0).midX, y: table.rect(ofRow: 0).midY), to: nil
        )
        table.mouseDown(with: try mouseEvent(.leftMouseDown, at: rowPoint, in: window))
        XCTAssertTrue(waitUntil { window.childWindows?.isEmpty == false },
                      "the hold must present the card")

        let card = try XCTUnwrap(window.childWindows?.first?.contentView)
        let scroll = try XCTUnwrap(card.subviews.compactMap { $0 as? NSScrollView }.first)
        let stack = try XCTUnwrap(scroll.documentView as? DocumentStackView,
                                  "the card's content must be the reading pane's engine")

        func contains<T: NSView>(_ type: T.Type, in view: NSView) -> Bool {
            view is T || view.subviews.contains { contains(type, in: $0) }
        }
        XCTAssertTrue(contains(TableBlockView.self, in: stack),
                      "the table must be drawn by the block view the page uses")
        XCTAssertTrue(contains(TextComponentView.self, in: stack),
                      "prose must be drawn by the component view the page uses")

        table.mouseUp(with: try mouseEvent(.leftMouseUp, at: rowPoint, in: window))
        controller.cancelPreview()
        waitUntil { (window.childWindows ?? []).isEmpty }
    }

    func testQuickClickNavigatesWithoutShowingACard() throws {
        OutlineTableView.holdDelay = 60
        let (controller, table, window) = try outline()
        var selected: String?
        controller.onSelect = { selected = $0 }
        let rowPoint = table.convert(
            NSPoint(x: table.rect(ofRow: 1).midX, y: table.rect(ofRow: 1).midY), to: nil
        )

        table.mouseDown(with: try mouseEvent(.leftMouseDown, at: rowPoint, in: window))
        table.mouseUp(with: try mouseEvent(.leftMouseUp, at: rowPoint, in: window))
        XCTAssertNotNil(selected, "a quick click must still navigate")
        XCTAssertEqual(window.childWindows?.count ?? 0, 0,
                       "a quick click must not present a card")
    }
}

/// Hover-to-peek on links in the reading pane: the same card the outline shows, anchored to
/// the hovered link, resolved through the document's own anchors.
final class LinkPeekIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The machine's real pointer must not haunt the hover checks: wherever it happens to
        // rest, it is never "inside the card" unless a test says so.
        PeekPreviewPanel.pointerLocation = { NSPoint(x: -100_000, y: -100_000) }
    }

    override func tearDown() {
        TextComponentView.linkHoverDelay = 0.4
        NativeDocumentView.linkHoverHideGrace = 0.15
        PeekPreviewPanel.pointerLocation = { NSEvent.mouseLocation }
        super.tearDown()
    }

    /// The link paragraph sits above two sections so the peek target (Gamma, outline index 1)
    /// is not the section already being read — a quick click has somewhere to report.
    private let linkSource = """
    Jump to [the gamma section](#gamma) or [the suite](https://example.com) first.

    ## Beta
    Beta body.

    ## Gamma
    Gamma body paragraph, the one the card must show.

    | a | b |
    |---|---|
    | 1 | 2 |

    ## Omega
    """

    private func pane() throws -> (NativeDocumentView, NSWindow) {
        let document = try makeDocument(linkSource)
        let view = NativeDocumentView(metrics: previewTestMetrics)
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: document, metrics: previewTestMetrics)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// The populated component holding the fixture's link, and the link's rect in its
    /// coordinates.
    private func linkView(in view: NativeDocumentView) throws -> (TextComponentView, NSRect) {
        let text = try XCTUnwrap(
            view.stackView.subviews
                .compactMap { $0 as? TextComponentView }
                .first { $0.linkRectForTests(destination: "#gamma") != nil },
            "the paragraph holding the link must be populated"
        )
        return (text, try XCTUnwrap(text.linkRectForTests(destination: "#gamma")))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testOnlyDestinationsWithSomethingToShowCanPeek() throws {
        let (view, _) = try pane()
        XCTAssertTrue(view.component(view, canPeekLink: "#gamma"))
        XCTAssertFalse(view.component(view, canPeekLink: "#omega"),
                       "a section with no body has nothing to peek")
        XCTAssertFalse(view.component(view, canPeekLink: "#nowhere"))
        XCTAssertTrue(view.component(view, canPeekLink: "https://example.com"),
                      "an http(s) link peeks the page in a web view")
        XCTAssertFalse(view.component(view, canPeekLink: "mailto:someone@example.com"),
                       "there is no page behind a mailto to show")
        XCTAssertFalse(view.component(view, canPeekLink: "no-such-file.md#gamma"),
                       "a link to a file that does not exist has nothing to peek")
    }

    func testHoverOnHttpsLinkPeeksAWebView() throws {
        TextComponentView.linkHoverDelay = 0.02
        let (view, window) = try pane()
        let text = try XCTUnwrap(
            view.stackView.subviews
                .compactMap { $0 as? TextComponentView }
                .first { $0.linkRectForTests(destination: "https://example.com") != nil }
        )
        let rect = try XCTUnwrap(text.linkRectForTests(destination: "https://example.com"))

        var reported: [Int] = []
        view.onHeadingChange = { reported.append($0) }

        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.midY))
        spin(0.08)
        let card = try XCTUnwrap(window.childWindows?.first?.contentView,
                                 "the hover must present the card")
        func contains<T: NSView>(_ type: T.Type, in view: NSView) -> Bool {
            view is T || view.subviews.contains { contains(type, in: $0) }
        }
        XCTAssertTrue(contains(WKWebView.self, in: card),
                      "an external page previews in a web view")
        XCTAssertTrue(reported.isEmpty, "a web peek must not navigate the document")

        view.linkPeek.hide()
        spin(0.3)
    }

    /// Navigation belongs to the click alone, delivered through NSTextView's own
    /// `clicked(onLink:)`. Called directly: synthesized events cannot drive the text view's
    /// stock mouse-tracking loop without hanging the test.
    func testClickOnLinkStillNavigates() throws {
        let (view, window) = try pane()
        let (text, _) = try linkView(in: view)

        var reported: [Int] = []
        view.onHeadingChange = { reported.append($0) }

        text.clicked(onLink: "#gamma", at: 0)

        XCTAssertEqual(window.childWindows?.count ?? 0, 0,
                       "a click must not present a card")
        XCTAssertEqual(reported.last, 1, "a click must still navigate to Gamma")
    }

    // MARK: Hover

    func testHoverOnLinkShowsTheCardWithoutBackdropOrNavigation() throws {
        TextComponentView.linkHoverDelay = 0.02
        let (view, window) = try pane()
        let (text, rect) = try linkView(in: view)

        var reported: [Int] = []
        view.onHeadingChange = { reported.append($0) }
        let origin = view.scrollView.contentView.bounds.origin
        let overlays = window.contentView?.subviews.count ?? 0

        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.midY))
        spin(0.08)
        XCTAssertEqual(window.childWindows?.count, 1, "resting on the link must show the card")
        XCTAssertFalse(view.linkPeek.presentsBackdrop, "a hover glance must not pin")
        XCTAssertEqual(window.contentView?.subviews.count, overlays,
                       "a hover must not dim the pane — nothing beneath it changes")
        XCTAssertEqual(view.scrollView.contentView.bounds.origin, origin,
                       "a hover must never move the reading position")
        XCTAssertTrue(reported.isEmpty, "a hover must not report a navigation")

        // The card draws the target section with the reading engine: Gamma holds a table, so
        // the card must contain the page's own TableBlockView.
        let card = try XCTUnwrap(window.childWindows?.first?.contentView)
        let scroll = try XCTUnwrap(card.subviews.compactMap { $0 as? NSScrollView }.first)
        let stack = try XCTUnwrap(scroll.documentView as? DocumentStackView)
        func contains<T: NSView>(_ type: T.Type, in view: NSView) -> Bool {
            view is T || view.subviews.contains { contains(type, in: $0) }
        }
        XCTAssertTrue(contains(TableBlockView.self, in: stack),
                      "the card must show Gamma's table through the reading engine")

        view.linkPeek.hide()
        spin(0.3)
    }

    func testPointerLeavingTheLinkHidesTheHoverCard() throws {
        TextComponentView.linkHoverDelay = 0.02
        NativeDocumentView.linkHoverHideGrace = 0.02
        let (view, window) = try pane()
        let (text, rect) = try linkView(in: view)

        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.midY))
        spin(0.08)
        XCTAssertTrue(view.linkPeek.isShown)

        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.maxY + 60))
        spin(0.4)
        XCTAssertEqual(window.childWindows?.count ?? 0, 0,
                       "the card must go once the pointer has moved on")
    }

    func testPointerOnTheCardKeepsTheHoverCardUp() throws {
        TextComponentView.linkHoverDelay = 0.02
        NativeDocumentView.linkHoverHideGrace = 0.02
        let (view, window) = try pane()
        let (text, rect) = try linkView(in: view)

        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.midY))
        spin(0.08)
        let card = try XCTUnwrap(window.childWindows?.first)
        // The pointer travels from the link onto the card.
        PeekPreviewPanel.pointerLocation = {
            NSPoint(x: card.frame.midX, y: card.frame.midY)
        }

        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.maxY + 60))
        spin(0.2)
        XCTAssertTrue(view.linkPeek.isShown,
                      "a card the pointer is reading must stay up")

        // And once the pointer leaves the card too, the card goes.
        PeekPreviewPanel.pointerLocation = { NSPoint(x: -100_000, y: -100_000) }
        view.componentHoverLeftLink(text)
        spin(0.4)
        XCTAssertEqual(window.childWindows?.count ?? 0, 0)
    }

    /// The click is delivered through `clicked(onLink:)` directly — synthesized events cannot
    /// drive NSTextView's stock mouse-tracking loop without hanging the test.
    func testClickWhileHoverCardIsUpNavigatesAndDismisses() throws {
        TextComponentView.linkHoverDelay = 0.02
        let (view, window) = try pane()
        let (text, rect) = try linkView(in: view)

        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.midY))
        spin(0.08)
        XCTAssertTrue(view.linkPeek.isShown)

        var reported: [Int] = []
        view.onHeadingChange = { reported.append($0) }
        text.clicked(onLink: "#gamma", at: 0)
        spin(0.3)

        XCTAssertEqual(reported.last, 1, "the click must still navigate to Gamma")
        XCTAssertEqual(window.childWindows?.count ?? 0, 0,
                       "and the glance must not outlive the decision to go")
    }
}

/// Peeks through relative markdown links — `foo.md`, `foo.md#section` — which parse and build
/// the target file. The vault's own links are percent-encoded and hold spaces, so the fixture
/// file does too.
final class RelativeFilePeekTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The machine's real pointer must not haunt the hover checks: wherever it happens to
        // rest, it is never "inside the card" unless a test says so.
        PeekPreviewPanel.pointerLocation = { NSPoint(x: -100_000, y: -100_000) }
    }

    override func tearDown() {
        TextComponentView.linkHoverDelay = 0.4
        PeekPreviewPanel.pointerLocation = { NSEvent.mouseLocation }
        super.tearDown()
    }

    private let targetSource = """
    # Kernel notes

    Opening paragraph about dispatch.

    ## Gamma
    Gamma body, the one the fragment link must show.

    | a | b |
    |---|---|
    | 1 | 2 |
    """

    private let linkSource = """
    See [the notes](Kernel%20notes.md) and \
    [gamma](Kernel%20notes.md#gamma) in the vault.
    """

    /// A vault directory of its own, so the relative links resolve deterministically.
    private func pane() throws -> (NativeDocumentView, NSWindow) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-peek-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try targetSource.write(to: dir.appendingPathComponent("Kernel notes.md"),
                               atomically: true, encoding: .utf8)
        let sourceURL = dir.appendingPathComponent("source.md")
        try linkSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        let document = try MarkdownDocument(url: sourceURL)

        let view = NativeDocumentView(metrics: previewTestMetrics)
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: document, metrics: previewTestMetrics)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func linkView(
        in view: NativeDocumentView, destination: String
    ) throws -> (TextComponentView, NSRect) {
        let text = try XCTUnwrap(
            view.stackView.subviews
                .compactMap { $0 as? TextComponentView }
                .first { $0.linkRectForTests(destination: destination) != nil }
        )
        return (text, try XCTUnwrap(text.linkRectForTests(destination: destination)))
    }

    private func hoverCard(
        on destination: String, view: NativeDocumentView, window: NSWindow
    ) throws -> NSView {
        let (text, rect) = try linkView(in: view, destination: destination)
        text.hoverMoved(to: NSPoint(x: rect.midX, y: rect.midY))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        return try XCTUnwrap(window.childWindows?.first?.contentView,
                             "the hover must present the card")
    }

    private func containsText(_ needle: String, in view: NSView) -> Bool {
        if let text = view as? NSTextView, text.string.contains(needle) { return true }
        return view.subviews.contains { containsText(needle, in: $0) }
    }

    private func contains<T: NSView>(_ type: T.Type, in view: NSView) -> Bool {
        view is T || view.subviews.contains { contains(type, in: $0) }
    }

    func testRelativeMarkdownLinksCanPeek() throws {
        let (view, _) = try pane()
        XCTAssertTrue(view.component(view, canPeekLink: "Kernel%20notes.md"),
                      "a percent-encoded relative link must peek the file")
        XCTAssertTrue(view.component(view, canPeekLink: "Kernel notes.md"),
                      "and the literal spelling must resolve to the same file")
        XCTAssertTrue(view.component(view, canPeekLink: "Kernel%20notes.md#gamma"))
        XCTAssertTrue(view.component(view, canPeekLink: "Kernel%20notes.md#no-such-anchor"),
                      "a fragment the target lacks still peeks the document itself")
        XCTAssertFalse(view.component(view, canPeekLink: "missing.md"))
    }

    func testFileLinkPeeksTheTargetsOpeningContent() throws {
        TextComponentView.linkHoverDelay = 0.02
        let (view, window) = try pane()
        let card = try hoverCard(on: "Kernel%20notes.md", view: view, window: window)
        XCTAssertTrue(containsText("Opening paragraph about dispatch", in: card),
                      "the card must open on the front of the target document")
        view.linkPeek.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func testFragmentIntoAnotherFilePeeksThatSection() throws {
        TextComponentView.linkHoverDelay = 0.02
        let (view, window) = try pane()
        let card = try hoverCard(on: "Kernel%20notes.md#gamma", view: view, window: window)
        XCTAssertTrue(contains(TableBlockView.self, in: card),
                      "the card must show Gamma's table through the reading engine")
        XCTAssertFalse(containsText("Opening paragraph about dispatch", in: card),
                       "and only Gamma — not the front of the document")
        view.linkPeek.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
}

/// The link hit test that gates the whole gesture.
final class LinkHitTests: XCTestCase {

    func testBlankSpacePastALinkLineIsNotALinkHit() throws {
        let view = TextComponentView()
        let attributed = NSMutableAttributedString(
            string: "See ",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.labelColor]
        )
        // The line ends with the link on purpose: the insertion index for the blank space past
        // it resolves to the link's last character, and only the laid-out rect says otherwise.
        attributed.append(NSAttributedString(string: "gamma", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .link: "#gamma",
        ]))
        view.setFrameSize(NSSize(width: 300, height: 40))
        view.configure(with: attributed, kind: .paragraph)

        let rect = try XCTUnwrap(view.linkRectForTests(destination: "#gamma"))
        XCTAssertEqual(view.link(at: NSPoint(x: rect.midX, y: rect.midY))?.destination,
                       "#gamma")
        XCTAssertNil(view.link(at: NSPoint(x: rect.maxX + 40, y: rect.midY)),
                     "blank space past the line must not read as the link")
    }
}

final class OutlinePressPreviewStateTests: XCTestCase {

    func testQuickPressAndReleaseIsAClick() {
        let press = PressPeekState()
        press.pressBegan(row: 3)
        XCTAssertEqual(press.released(pointerRow: 3), .click(3))
    }

    func testReleaseOnAnotherRowWithoutPreviewIsNothing() {
        let press = PressPeekState()
        press.pressBegan(row: 3)
        XCTAssertEqual(press.released(pointerRow: 5), .none)
    }

    func testHoldShowsAndReleasePinsWithoutClicking() {
        let press = PressPeekState()
        press.pressBegan(row: 3)
        XCTAssertEqual(press.holdFired(pointerRow: 3), .show(3))
        XCTAssertEqual(press.released(pointerRow: 3), .pin,
                       "a peek's release keeps the card up and must never navigate")
    }

    func testForceClickShowsImmediatelyAndOnlyOnce() {
        let press = PressPeekState()
        press.pressBegan(row: 2)
        XCTAssertEqual(press.forceClicked(pointerRow: 2), .show(2))
        XCTAssertEqual(press.holdFired(pointerRow: 2), .none,
                       "a late hold timer must not re-show over a force click")
    }

    func testScrubUpdatesAndPointerOffRowsHides() {
        let press = PressPeekState()
        press.pressBegan(row: 1)
        XCTAssertEqual(press.holdFired(pointerRow: 1), .show(1))
        XCTAssertEqual(press.pointerMoved(toRow: 2), .update(2))
        XCTAssertEqual(press.pointerMoved(toRow: 2), .none, "same row is not a change")
        XCTAssertEqual(press.pointerMoved(toRow: -1), .update(-1), "off the rows hides the card")
        XCTAssertEqual(press.pointerMoved(toRow: 1), .update(1), "and back restores it")
    }

    func testMovesBeforeTheThresholdDoNothing() {
        let press = PressPeekState()
        press.pressBegan(row: 1)
        XCTAssertEqual(press.pointerMoved(toRow: 2), .none)
    }

    func testCancelEndsThePressSilently() {
        let press = PressPeekState()
        press.pressBegan(row: 1)
        _ = press.holdFired(pointerRow: 1)
        press.cancel()
        XCTAssertEqual(press.released(pointerRow: 1), .none)
    }

    func testHoldAfterCancelDoesNotShow() {
        let press = PressPeekState()
        press.pressBegan(row: 1)
        press.cancel()
        XCTAssertEqual(press.holdFired(pointerRow: 1), .none,
                       "a timer that outlives its press must not present a card")
    }
}
