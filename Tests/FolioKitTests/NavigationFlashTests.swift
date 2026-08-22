import AppKit
import XCTest
@testable import FolioKit

/// The landing flash: a glow behind the component a reader navigated to.
///
/// In a spread a click can land anywhere on the page — the foot of a column, the top of the
/// right-hand one — and a heading that merely appears somewhere is easy to miss.
final class NavigationFlashTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    override func tearDown() {
        DocumentStackView.flashDuration = 1.1
        super.tearDown()
    }

    private func pane(width: CGFloat = 1500) throws -> (NativeDocumentView, MarkdownDocument) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        let document = try MarkdownDocument(url: url)
        let view = NativeDocumentView(metrics: metrics)
        // Unanimated: the flash fires on arrival, and this test is not about the easing.
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
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

    func testNavigatingFlashesTheTarget() throws {
        let (view, document) = try pane()
        XCTAssertEqual(view.stackView.flashCount, 0, "nothing should be flashing yet")

        let target = try XCTUnwrap(document.outline.firstIndex { $0.title.hasPrefix("2.2") })
        view.scroll(toAnchor: document.outline[target].anchor)
        XCTAssertEqual(view.stackView.flashCount, 1, "the target was not flashed")
    }

    /// The glow covers the component, with a margin, so it reads as a glow around the block.
    func testTheFlashCoversTheComponent() throws {
        let (view, document) = try pane()
        let target = try XCTUnwrap(document.outline.firstIndex { $0.title.hasPrefix("2.2") })
        let range = try XCTUnwrap(view.built?.anchors[document.outline[target].anchor])
        let component = try XCTUnwrap(view.built?.componentIndex(containing: range.location))

        view.scroll(toAnchor: document.outline[target].anchor)
        let glow = try XCTUnwrap(view.stackView.subviews.compactMap { $0 as? FlashView }.first)
        let frame = view.stackView.frame(ofComponent: component)
        XCTAssertTrue(glow.frame.insetBy(dx: -1, dy: -1).contains(frame),
                      "the glow \(glow.frame.integral) does not cover the component "
                          + "\(frame.integral)")
        XCTAssertNil(glow.hitTest(NSPoint(x: glow.bounds.midX, y: glow.bounds.midY)),
                     "the glow must not swallow clicks")
    }

    func testTheFlashFadesAway() throws {
        DocumentStackView.flashDuration = 0.05
        let (view, document) = try pane()
        let target = try XCTUnwrap(document.outline.firstIndex { $0.title.hasPrefix("2.2") })
        view.scroll(toAnchor: document.outline[target].anchor)
        XCTAssertEqual(view.stackView.flashCount, 1)

        XCTAssertTrue(waitUntil(2) { view.stackView.flashCount == 0 },
                      "the glow never went away")
    }

    /// A restore after a reflow puts the reader back where they already were; there is nothing to
    /// point out, and a glow would be noise.
    func testRestoringDoesNotFlash() throws {
        let (view, _) = try pane()
        view.restore(view.captureScrollAnchor())
        for _ in 0..<5 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(view.stackView.flashCount, 0, "a restore should not flash")
    }

    /// Every page of a split table flashes: all of them are what the reader asked for.
    func testAllPagesOfASplitComponentFlash() throws {
        var lines = ["# Contents", "", "| Chapter | Page |", "| --- | --- |"]
        for row in 1...200 { lines.append("| \(row). Section | \(row) |") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-flash-\(UUID().uuidString).md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let view = NativeDocumentView(metrics: metrics)
        view.animatesNavigation = false
        view.frame = NSRect(x: 0, y: 0, width: 1600, height: 800)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try MarkdownDocument(url: url), metrics: metrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        let table = try XCTUnwrap(view.built?.components.firstIndex {
            if case .widget(.table) = $0.content { return true } else { return false }
        })
        let pages = view.stackView.placementCount(ofComponent: table)
        XCTAssertGreaterThan(pages, 1, "the fixture should split")

        view.scroll(toComponent: table)
        XCTAssertEqual(view.stackView.flashCount, pages,
                       "only some pages of the table were flashed")
    }
}
