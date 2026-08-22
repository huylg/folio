import AppKit
import XCTest
@testable import FolioKit

/// Pins the reading column's geometry against the pane it is actually in.
///
/// Regression cover for a real breakage: the source pane taking a third of the window shrank
/// the document pane, but the centring inset had been computed for the old wider pane and was
/// never recalculated — because the guard compared the *measure*, which is clamped to the
/// reading column and therefore identical at both widths. The stale inset drove the text
/// container's width negative, so prose stopped wrapping and every block widget collapsed to a
/// couple of points wide.
final class ReadingColumnTests: XCTestCase {

    private func sampleURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
    }

    private func makeView(width: CGFloat) throws -> NativeDocumentView {
        let metrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                      lineWidth: .comfortable, density: .airy)
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        // A window is required: attachment views are vended by the viewport layout controller,
        // which only runs for a text view inside one.
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try MarkdownDocument(url: sampleURL()), metrics: metrics)
        settle(view)
        return view
    }

    private func settle(_ view: NativeDocumentView) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<8 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
    }

    private func resize(_ view: NativeDocumentView, to width: CGFloat) {
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.frame.height)
        view.window?.setContentSize(NSSize(width: width, height: view.frame.height))
        // The reflow is debounced — a size change coalesces the frames of an animation instead of
        // re-paginating on each one — so the new layout arrives a moment after the resize.
        let expected = view.settledLayoutForTests
        _ = waitUntil {
            view.stackView.columnCount == expected.columns
                && view.stackView.frame(ofComponent: 0).width == expected.columnWidth
        }
        settle(view)
    }

    /// Every component is one column wide, and the columns are centred in the pane.
    ///
    /// Written for either layout: a wide pane holds a two-column spread, a narrow one a single
    /// column, and the invariant — equal column widths, centred as a group, inside the pane — is
    /// the same either way.
    ///
    /// Compared against the pane with an allowance: the scroll view reserves room for the
    /// vertical scroller, so the stack is legitimately a scroller-width narrower.
    private func assertConsistent(_ view: NativeDocumentView,
                                  paneWidth: CGFloat,
                                  line: UInt = #line) {
        let stack = view.stackView
        let scrollerAllowance: CGFloat = 20
        XCTAssertGreaterThanOrEqual(stack.frame.width, paneWidth - scrollerAllowance,
                                    "the stack is far narrower than its pane", line: line)

        let frames = (0..<6).map { stack.frame(ofComponent: $0) }
        let column = frames.first?.width ?? 0
        XCTAssertGreaterThan(column, 0, "component width collapsed", line: line)

        let columns = CGFloat(stack.columnCount)
        let total = column * columns + DocumentStackView.gutter * (columns - 1)
        XCTAssertLessThanOrEqual(total, paneWidth,
                                 "the columns are wider than their pane", line: line)

        let leftEdge = ((stack.frame.width - total) / 2).rounded()
        for frame in frames {
            XCTAssertEqual(frame.width, column, accuracy: 1,
                           "components disagree about the column width", line: line)
            // Every component sits at one of the columns' left edges.
            let offsets = (0..<stack.columnCount).map {
                leftEdge + CGFloat($0) * (column + DocumentStackView.gutter)
            }
            XCTAssertTrue(offsets.contains { abs($0 - frame.minX) <= 1 },
                          "a component at x \(frame.minX) is in no column "
                              + "(expected one of \(offsets))", line: line)
        }
    }

    func testColumnIsConsistentAtAWideWidth() throws {
        let width = paneWidth(forColumns: 3)
        let view = try makeView(width: width)
        assertConsistent(view, paneWidth: width)
        XCTAssertEqual(view.stackView.columnCount, 3,
                       "a pane with room for three columns should use them")
    }

    /// The failing case from the screenshot: a wide pane narrowed to roughly two thirds when the
    /// source pane opened.
    func testColumnRecalculatesWhenThePaneNarrows() throws {
        let view = try makeView(width: paneWidth(forColumns: 3))
        resize(view, to: paneWidth(forColumns: 2))
        assertConsistent(view, paneWidth: paneWidth(forColumns: 2))
    }

    func testColumnSurvivesRepeatedResizes() throws {
        let view = try makeView(width: paneWidth(forColumns: 2))
        // Across every band, and back and forth over each threshold.
        for width in [paneWidth(forColumns: 1), paneWidth(forColumns: 3),
                      700, paneWidth(forColumns: 2), 480, paneWidth(forColumns: 3) + 400] {
            resize(view, to: width)
            assertConsistent(view, paneWidth: width)
        }
    }

    /// Below the measure the column stops centring and keeps only the minimum padding, rather
    /// than letting the inset eat the whole pane.
    func testNarrowPaneFallsBackToMinimumPadding() throws {
        let view = try makeView(width: 420)
        assertConsistent(view, paneWidth: 420)
        let frame = view.stackView.frame(ofComponent: 0)
        XCTAssertLessThanOrEqual(frame.minX, DocumentMetrics.minimumPadding + 1,
                                 "a pane narrower than the measure should stop centring")
    }

    /// A widget fills the column. As an attachment it took its width from the line fragment it
    /// sat in, so a broken container showed up as cards a couple of points wide.
    func testBlockWidgetsGetTheColumnWidth() throws {
        let view = try makeView(width: paneWidth(forColumns: 3))
        resize(view, to: paneWidth(forColumns: 2))

        let stack = view.stackView
        let column = stack.frame(ofComponent: 0).width
        let widgets = view.built?.components.enumerated().filter {
            if case .widget = $0.element.content { return true } else { return false }
        } ?? []
        XCTAssertFalse(widgets.isEmpty, "fixture should contain block widgets")

        for (index, _) in widgets {
            XCTAssertEqual(stack.frame(ofComponent: index).width, column, accuracy: 1,
                           "a widget component is not the column's width")
        }
    }
}
