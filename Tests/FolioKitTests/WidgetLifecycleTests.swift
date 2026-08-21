import AppKit
import XCTest
@testable import FolioKit

/// Regression cover for block widgets not appearing until the window was resized.
///
/// Two independent failures, both of which only show up when a document is opened into a pane
/// that has *already* laid out — the app's order, and the one no test covered:
///
/// 1. Attachments were measured before any view provider existed, so AppKit fell back to the
///    placeholder image's 1×1 bounds; the frontmatter card was a dot with no space reserved.
/// 2. The viewport layout controller does not re-run when a laid-out text view's content is
///    replaced, so no widget view was vended at all.
final class WidgetLifecycleTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func sampleDocument() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    private func settle(_ view: NSView, turns: Int = 12) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// A window is required: attachment views are vended by the viewport layout controller,
    /// which only runs for a text view inside one.
    private func paneOnScreen() -> NativeDocumentView {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        // The pane lays out empty first, exactly as it does while the app waits for a file.
        settle(view)
        return view
    }

    func testFirstBlockGetsItsViewWhenOpenedIntoALaidOutPane() throws {
        let view = paneOnScreen()
        view.render(document: try sampleDocument(), metrics: metrics)
        settle(view)

        // The frontmatter card is the document's first component.
        let card = try XCTUnwrap(view.stackView.subviews.first, "no component view was built")
        XCTAssertGreaterThan(card.frame.width, 100, "the component collapsed")
        XCTAssertGreaterThan(card.frame.height, 40, "the component collapsed")
    }

    /// Every component reserves height before anything is built, which is what lets the stack
    /// position the document and size the scroller in one pass.
    func testEveryComponentReservesItsHeight() throws {
        let view = paneOnScreen()
        view.render(document: try sampleDocument(), metrics: metrics)
        settle(view)

        let built = try XCTUnwrap(view.built)
        for index in built.components.indices {
            let frame = view.stackView.frame(ofComponent: index)
            XCTAssertGreaterThan(frame.height, 0,
                                 "\(built.components[index].kind) reserved no height")
        }
        // And they stack in order, with no overlap.
        for index in 1..<built.components.count {
            let previous = view.stackView.frame(ofComponent: index - 1)
            let current = view.stackView.frame(ofComponent: index)
            XCTAssertGreaterThanOrEqual(current.minY, previous.maxY - 0.5,
                                        "component \(index) overlaps the one above it")
        }
    }

    /// Only the components near the viewport are built: a document of any length costs the same
    /// handful of views.
    func testOnlyNearbyComponentsAreBuilt() throws {
        let view = paneOnScreen()
        view.render(document: try sampleDocument(), metrics: metrics)
        settle(view)

        let built = try XCTUnwrap(view.built)
        XCTAssertLessThan(view.stackView.subviews.count, built.components.count,
                          "every component was built at once")
        XCTAssertGreaterThan(view.stackView.subviews.count, 0, "nothing was built")
    }
}

/// Regression cover for the outline highlighting the wrong entry after a click.
///
/// Navigating parks the target heading 12pt below the viewport's top edge, while the
/// "currently reading" probe sits at 80 — so a section shorter than that reported its
/// *successor*: clicking "2 Method" highlighted "2.1 Block-sparse routing".
final class OutlineTrackingTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func sampleDocument() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    private func settle(_ view: NSView, turns: Int = 12) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// Every heading in the outline, clicked, lands on itself.
    ///
    /// The last sections used to be unreachable: a scroll clamps at the end of the document, so
    /// the heading stayed mid-viewport and the reading-line probe reported whatever sat below it.
    /// Clicking "3.2 Throughput" or "4 Limitations" highlighted "References". The stack now keeps
    /// enough space after the document for any heading to be parked at the top.
    func testEveryHeadingCanBeNavigatedTo() throws {
        let document = try sampleDocument()
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)

        var current = -1
        view.onHeadingChange = { current = $0 }
        view.animatesNavigation = false
        view.render(document: document, metrics: metrics)
        settle(view)

        for target in document.outline.indices {
            view.scroll(toAnchor: document.outline[target].anchor)
            waitUntil { current == target }
            settle(view, turns: 4)
            XCTAssertEqual(current, target,
                           "clicking '\(document.outline[target].title)' landed on "
                               + "'\(current >= 0 ? document.outline[current].title : "nothing")'")
        }
    }

    func testClickingAShortSectionReportsThatSection() throws {
        let document = try sampleDocument()
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: document, metrics: metrics)
        settle(view)

        var reported: Int?
        view.onHeadingChange = { reported = $0 }
        view.animatesNavigation = false

        // "2 Method" — two lines of prose before "2.1 Block-sparse routing".
        let target = try XCTUnwrap(document.outline.firstIndex { $0.title.hasPrefix("2 Method") })
        view.scroll(toAnchor: document.outline[target].anchor)

        // Reported before the scroll animation even starts.
        XCTAssertEqual(reported, target, "the click itself did not move the outline")

        // And still the reported section once the viewport has arrived and the probe takes over.
        settle(view, turns: 60)
        XCTAssertEqual(reported, target,
                       "outline settled on \(reported.map { document.outline[$0].title } ?? "nothing")")
        XCTAssertGreaterThan(view.scrollView.contentView.bounds.origin.y, 0,
                             "the viewport never moved")
    }
}

/// Selection is per component now, so this is the feature the refactor traded document-wide
/// selection for: it has to actually work inside a block.
final class ComponentSelectionTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func pane() throws -> NativeDocumentView {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try MarkdownDocument(url: url), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<12 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return view
    }

    private func textComponents(in view: NativeDocumentView) -> [TextComponentView] {
        view.stackView.subviews.compactMap { $0 as? TextComponentView }
    }

    func testProseComponentsAreSelectable() throws {
        let view = try pane()
        let components = textComponents(in: view)
        XCTAssertFalse(components.isEmpty, "no prose component was built")

        let component = try XCTUnwrap(components.first { $0.string.count > 20 })
        component.selectAll(nil)
        XCTAssertEqual(component.selectedRange().length, component.string.count,
                       "⌘A inside a component selected nothing")
        XCTAssertFalse(component.isEditable, "the reading pane must stay read-only")
    }

    /// A code card's body is a text component too, so code selects and copies as code.
    func testCodeCardsAreSelectable() throws {
        let view = try pane()
        let card = try XCTUnwrap(view.stackView.subviews.compactMap { $0 as? CodeComponentView }.first)
        let body = try XCTUnwrap(card.subviews.compactMap { $0 as? TextComponentView }.first)
        body.selectAll(nil)
        XCTAssertGreaterThan(body.selectedRange().length, 0, "code did not select")
        XCTAssertTrue(card.source.contains("def route") || card.source.contains("func dispatch"),
                      "the card's copy button would copy the wrong source")
    }

    /// Focusing one component releases the others, so only one selection is ever live.
    func testOnlyOneComponentHoldsASelection() throws {
        let view = try pane()
        let components = textComponents(in: view).filter { $0.string.count > 20 }
        guard components.count >= 2 else { return XCTFail("need two prose components") }

        components[0].selectAll(nil)
        XCTAssertGreaterThan(components[0].selectedRange().length, 0)

        view.window?.makeFirstResponder(components[1])
        components[1].selectAll(nil)
        XCTAssertEqual(components[0].selectedRange().length, 0,
                       "the previous component kept its selection")
        XCTAssertGreaterThan(components[1].selectedRange().length, 0)
    }
}

/// Spins the run loop until `condition` holds, or the deadline passes.
///
/// Fixed turn counts are not enough: the scroll animation takes 300ms of wall clock, and under the
/// load of a full test run a fixed settle can end before it does.
@discardableResult
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return condition()
}

/// The navigation pin has to outlive the scroll that is carrying the reader there.
///
/// An animated scroll's completion handler can run before the viewport has finished moving, so
/// checking "is the target at the top yet?" at that moment says no — and releasing the pin on that
/// first mismatch reported the *previous* section: click "1.1 Motivation", get "1 Introduction".
/// The pin now holds until the target arrives once, and the reader's own scrolling releases it
/// immediately whatever the animation is doing.
final class NavigationPinTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func paneAndDocument() throws -> (NativeDocumentView, MarkdownDocument) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        let document = try MarkdownDocument(url: url)
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: document, metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return (view, document)
    }

    /// Mid-flight — before the viewport has moved — the outline already shows the destination and
    /// keeps showing it.
    func testPinHoldsWhileTheScrollIsStillInFlight() throws {
        let (view, document) = try paneAndDocument()
        var current = -1
        view.onHeadingChange = { current = $0 }

        let target = try XCTUnwrap(document.outline.firstIndex { $0.title.hasPrefix("1.1") })
        view.scroll(toAnchor: document.outline[target].anchor)

        // One turn: the animation has barely begun, and its completion may already have run.
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        XCTAssertEqual(current, target, "the outline fell back to the previous section mid-scroll")

        waitUntil { view.scrollView.contentView.bounds.minY > 0 }
        XCTAssertEqual(current, target, "the outline did not settle on the destination")
    }

    /// The reader taking over releases the pin, so tracking follows them again.
    func testReaderScrollingReleasesThePin() throws {
        let (view, document) = try paneAndDocument()
        let target = try XCTUnwrap(document.outline.firstIndex { $0.title.hasPrefix("1.1") })
        // Unanimated: the subject here is the pin's release, and waiting on a 300ms animation
        // makes the test's outcome depend on how busy the machine is.
        view.animatesNavigation = false
        var arrived = -1
        view.onHeadingChange = { arrived = $0 }
        view.scroll(toAnchor: document.outline[target].anchor)
        XCTAssertTrue(waitUntil { arrived == target && view.scrollView.contentView.bounds.minY > 0 },
                      "the navigation never landed")

        var current = -1
        view.onHeadingChange = { current = $0 }
        // The notification AppKit posts for trackpad, wheel and scroller drags — never for a
        // programmatic scroll.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
                                        object: view.scrollView)
        let documentHeight = try XCTUnwrap(view.scrollView.documentView).frame.height
        view.scrollView.contentView.scroll(to: NSPoint(x: 0, y: documentHeight * 0.75))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        waitUntil { current > target }
        XCTAssertGreaterThan(current, target,
                             "tracking stayed pinned to the click after the reader scrolled away")
    }
}
