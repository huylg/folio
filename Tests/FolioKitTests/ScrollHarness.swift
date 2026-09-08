import AppKit
import XCTest
@testable import FolioKit

/// A scroll trace without a trackpad.
///
/// Drives the reading pane through scripted gestures — a slow read, a flick, a scroll back, a
/// stretch deep in the document — with the tracer attached, and prints each gesture's summary
/// the way `FOLIO_SCROLL_TRACE` does under the window. For chasing a scroll cost on a machine
/// where nobody can put a hand on the trackpad: an agent's session, a CI runner. The pane is
/// mounted the way the app mounts it, under a layer-backed view, because the display path — and
/// so where the text gets painted — is different in a plain window.
///
/// Skipped unless `FOLIO_SCROLL_HARNESS` is set: it prints rather than asserts, and it takes a
/// few seconds. `FOLIO_HARNESS_PARAGRAPHS` sizes the document (1,500 by default, about 1,900
/// components; 6,000 is a book), `FOLIO_HARNESS_WIDTH` the pane. Under `-c release` the numbers
/// are the app's; the test target then needs `-Xswiftc -enable-testing`:
///
/// ```
/// FOLIO_SCROLL_HARNESS=1 FOLIO_HARNESS_PARAGRAPHS=6000 \
///     swift test -c release -Xswiftc -enable-testing --filter ScrollHarness 2>&1 | grep '^\['
/// ```
final class ScrollHarness: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Prose with the furniture a real document has — headings, tables, code, lists, quotes —
    /// at the rates a long technical document tends to.
    private func longDocument(paragraphs: Int) throws -> MarkdownDocument {
        var lines = ["---", "title: Harness", "author: Test", "---", "", "# Harness", ""]
        for index in 1...paragraphs {
            if index % 12 == 0 { lines += ["## Section \(index / 12)", ""] }
            if index % 40 == 0 { lines += ["### Detail \(index / 40)", ""] }
            lines += ["Paragraph \(index) with enough words to wrap at a normal measure and take "
                        + "more than one line of the reading column, and then a [link](#harness) "
                        + "and some *emphasis* so the attributed string is not trivial.", ""]
            if index % 25 == 0 {
                lines += ["| Item | Page | Notes |", "| --- | --- | --- |",
                          "| One | 1 | first |", "| Two | 2 | second |", "| Three | 3 | third |", ""]
            }
            if index % 30 == 0 {
                lines += ["```swift", "let x = \(index)", "print(x)", "```", ""]
            }
            if index % 17 == 0 {
                lines += ["- item one of a list", "- item two of a list", "- item three", ""]
            }
            if index % 23 == 0 {
                lines += ["> A quotation that runs long enough to wrap onto a second line in the "
                            + "reading column.", ""]
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-harness-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MarkdownDocument(url: url)
    }

    /// Runs the loop for `seconds`, so AppKit's display pass — where a frame is actually spent —
    /// runs between the scroll events the way it does under a gesture.
    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    func testTraceScriptedGestures() throws {
        try XCTSkipUnless(env["FOLIO_SCROLL_HARNESS"] != nil,
                          "set FOLIO_SCROLL_HARNESS=1 to print a trace of scripted gestures")
        let paragraphs = Int(env["FOLIO_HARNESS_PARAGRAPHS"] ?? "") ?? 1500
        let width = CGFloat(Double(env["FOLIO_HARNESS_WIDTH"] ?? "") ?? 1100)
        let height: CGFloat = 800
        let metrics = testMetrics

        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let window = TestWindow(
            contentRect: NSRect(x: 100, y: 100, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        // As `DocumentViewController` mounts it: the pane under a layer-backed container.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        let view = NativeDocumentView(metrics: metrics)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        // On screen, so the display pass really draws; ordered back, it would not.
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        // Wired as the window wires them, so the section report and heading probe run.
        view.onHeadingChange = { _ in }
        view.onVisibleSectionsChange = { _ in }

        var lines: [String] = []
        let trace = ScrollTrace(enabled: true)
        trace.sink = { lines.append($0) }
        let previous = ScrollTrace.shared
        ScrollTrace.shared = trace
        defer { ScrollTrace.shared = previous }

        let document = try longDocument(paragraphs: paragraphs)
        view.render(document: document, metrics: metrics)
        view.layoutSubtreeIfNeeded()
        spin(0.3)
        let stack = view.stackView
        print("[harness] \(view.built?.components.count ?? 0) components in "
              + "\(stack.columnCount) column(s), \(Int(stack.contentHeight))pt tall")

        let clip = view.scrollView.contentView
        let maxY = stack.frame.height - clip.bounds.height

        /// One gesture: `steps` scroll events from `from` to `to`, a frame apart, then the
        /// settle the tracer waits for before it prints.
        func gesture(_ name: String, from: CGFloat, to: CGFloat, steps: Int) {
            lines = []
            let visited = stack.placementsVisited
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
                                            object: view.scrollView)
            for step in 1...steps {
                let y = from + (to - from) * CGFloat(step) / CGFloat(steps)
                clip.scroll(to: NSPoint(x: 0, y: min(max(-52, y), maxY)))
                view.scrollView.reflectScrolledClipView(clip)
                spin(1.0 / 60)
            }
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
                                            object: view.scrollView)
            spin(ScrollTrace.settleDelay + 0.15)
            print("[harness] --- \(name): \(steps) events of \(Int((to - from) / CGFloat(steps)))pt, "
                  + "\(stack.subviews.count) views live, "
                  + "\(stack.placementsVisited - visited) placements examined")
            for line in lines { print(line) }
        }

        gesture("slow read", from: 0, to: 1200, steps: 60)
        gesture("flick", from: 1200, to: 10200, steps: 45)
        gesture("back up", from: 10200, to: 5200, steps: 50)
        gesture("deep in the document", from: maxY - 6000, to: maxY - 1000, steps: 50)
        withExtendedLifetime(window) {}
    }
}
