import AppKit
import XCTest
@testable import FolioKit

/// Locks the palette's contrast floors.
///
/// Regression cover for grey text being unreadable. The palette originally mapped the design's
/// ink ramp onto Apple's lower label colors, which are tuned for placeholder and disabled
/// states: against the reading surface `tertiaryLabelColor` measures 2.3:1 and
/// `quaternaryLabelColor` 1.3:1, against a 4.5:1 floor for small text.
final class ContrastTests: XCTestCase {

    /// Folio is dark only, so there is one appearance to satisfy.
    private var appearance: NSAppearance { NSAppearance(named: .darkAqua)! }

    /// Surfaces are translucent by design, so flatten them over the page to get the backdrop a
    /// reader actually sees.
    private func surface(_ color: NSColor) -> NSColor {
        color.flattened(over: Ink.page, appearance: appearance) ?? color
    }

    private func ratio(_ color: NSColor, on background: NSColor) -> CGFloat {
        color.contrastRatio(on: surface(background), appearance: appearance) ?? 0
    }

    /// WCAG AA for small text, which is what the HIG's accessibility page audits against.
    private let readableFloor: CGFloat = 4.5
    /// The HIG's stated target for custom colors in small text.
    private let bodyTarget: CGFloat = 7.0

    func testBodyAndHeadingsClearTheBodyTarget() {
        for (name, color) in [("body", Ink.body), ("heading", Ink.heading)] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: Ink.page), bodyTarget,
                                        "\(name) is below the 7:1 body target")
        }
    }

    /// Every tier that carries text a reader is expected to read.
    func testReadableTiersClearTheFloor() {
        let tiers: [(String, NSColor)] = [
            ("body", Ink.body),
            ("secondary", Ink.secondary),
            ("tertiary", Ink.tertiary),
            ("faint", Ink.faint),
            ("link", Ink.link),
        ]
        for (name, color) in tiers {
            for (surfaceName, surface) in [("page", Ink.page),
                                           ("cardFill", Ink.cardFill),
                                           ("codeBackground", Ink.codeBackground),
                                           ("diagramBackground", Ink.diagramBackground)] {
                let measured = ratio(color, on: surface)
                XCTAssertGreaterThanOrEqual(
                    measured, readableFloor,
                    "\(name) on \(surfaceName) is \(String(format: "%.2f", measured)):1, "
                        + "below the \(readableFloor):1 floor"
                )
            }
        }
    }

    /// A node's label sits on a tinted fill, which is translucent over the diagram canvas.
    /// `tintFill` is the accent at 0.28 alpha, so this is a real question rather than a
    /// formality.
    func testDiagramNodeTextIsReadableOnATintedNode() {
        let canvas = surface(Ink.diagramBackground)
        for fill in [Ink.tintFill, Ink.cardFillStrong] {
            let backdrop = fill.flattened(over: canvas, appearance: appearance) ?? canvas
            let measured = Ink.body.contrastRatio(on: backdrop, appearance: appearance) ?? 0
            XCTAssertGreaterThanOrEqual(
                measured, readableFloor,
                "node text is \(String(format: "%.2f", measured)):1 on a diagram node"
            )
        }
    }

    /// Edges and node borders are non-text marks, which WCAG 1.4.11 floors at 3:1. An edge is
    /// what the diagram *says*, so it has to clear that: `decorative` and `hairlineStrong` both
    /// disappear against this canvas, which is why the diagram palette has its own two entries.
    func testDiagramMarksClearTheNonTextFloor() {
        let nonTextFloor: CGFloat = 3.0
        for (name, color) in [("diagramEdge", Ink.diagramEdge),
                              ("diagramStroke", Ink.diagramStroke)] {
            for (surfaceName, backdrop) in [("canvas", Ink.diagramBackground),
                                            ("node", Ink.cardFillStrong)] {
                let measured = ratio(color, on: backdrop)
                XCTAssertGreaterThanOrEqual(
                    measured, nonTextFloor,
                    "\(name) on \(surfaceName) is \(String(format: "%.2f", measured)):1, "
                        + "below the \(nonTextFloor):1 floor for non-text marks"
                )
            }
        }
    }

    /// Syntax colors sit on the code surface and are read as prose. Comments especially — a
    /// plain `.systemGray` fell under the floor there.
    func testSyntaxColorsClearTheFloor() {
        for token in SyntaxHighlighter.TokenClass.allCases {
            let measured = ratio(Ink.syntax(token), on: Ink.codeBackground)
            XCTAssertGreaterThanOrEqual(
                measured, readableFloor,
                "syntax \(token) is \(String(format: "%.2f", measured)):1 on the code background"
            )
        }
    }

    /// Tag pill text sits on its own tinted fill, which is translucent over a card.
    func testTagPillTextIsReadable() {
        let card = surface(Ink.cardFill)
        for tag in ["attention", "efficiency", "to-cite", "reviewed", "a", "λ"] {
            let pill = TagPalette.pill(for: tag)
            let backdrop = pill.fill.flattened(over: card, appearance: appearance) ?? card
            let measured = pill.text.contrastRatio(on: backdrop, appearance: appearance) ?? 0
            XCTAssertGreaterThanOrEqual(
                measured, readableFloor,
                "pill text for '\(tag)' is \(String(format: "%.2f", measured)):1"
            )
        }
    }

    /// `controlAccentColor` is the *user's* chosen accent and Apple offers no contrast
    /// guarantee for it — in the default blue it measures about 4.15:1 here. It is therefore
    /// deliberately outside the floor, and is only used where weight or shape carries the
    /// meaning too: the current outline row, a checked checkbox, the blockquote bar.
    func testAccentIsDocumentedAsExemptButNotInvisible() {
        let measured = ratio(Ink.accent, on: Ink.page)
        XCTAssertGreaterThanOrEqual(measured, 3.0,
                                    "accent has fallen below even the large-text floor")
    }

    /// The tiers must actually differ, or the hierarchy they encode is decorative.
    func testTiersAreDistinguishable() {
        let ordered = [Ink.body, Ink.secondary, Ink.tertiary, Ink.decorative]
        let ratios = ordered.map { ratio($0, on: Ink.page) }
        for (stronger, weaker) in zip(ratios, ratios.dropFirst()) {
            XCTAssertGreaterThan(stronger, weaker * 1.08,
                                 "adjacent ink tiers are too close to tell apart: \(ratios)")
        }
    }

    /// `decorative` is explicitly exempt from the floor — this pins the intent so nobody
    /// "fixes" it by using it for text.
    /// The outline's own markings: the pointer's pill and the block over the sections on screen.
    /// Both are ours to get right, and a label sits on top of each.
    func testOutlineMarkingsKeepTheirLabelsReadable() {
        for (name, tint) in [("under the pointer", OutlineRowView.hoverTint),
                             ("in the visible group", OutlineIndicatorView.tint)] {
            let pill = Ink.accent.withAlphaComponent(tint)
            XCTAssertGreaterThanOrEqual(ratio(Ink.secondary, on: pill), readableFloor,
                                        "a row \(name) has an unreadable label")
            XCTAssertGreaterThanOrEqual(ratio(Ink.body, on: pill), readableFloor,
                                        "a row \(name) has an unreadable label")
        }

        // The block is quieter than the pointer's own marking: it is context, not an answer to a
        // question the reader is asking right now.
        XCTAssertLessThan(OutlineIndicatorView.tint, OutlineRowView.hoverTint)
    }

    func testDecorativeIsBelowTheFloorByDesign() {
        XCTAssertLessThan(ratio(Ink.decorative, on: Ink.page), bodyTarget)
    }
}

/// Regression cover for several rows showing the hover pill at once.
///
/// Hover used to be tracked by a tracking area on every row. Rows are recycled and scrolled
/// under a stationary pointer, `mouseExited` does not always arrive for one being reused, and the
/// state was left set on three rows at the same time. It is now derived from one mouse position
/// and pushed to every live row on each update.
final class OutlineHoverStateTests: XCTestCase {

    private func outline() throws -> (OutlineViewController, OutlineTableView) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        let controller = OutlineViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        let window = TestWindow(contentRect: controller.view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderBack(nil)
        controller.update(document: try MarkdownDocument(url: url))
        controller.view.layoutSubtreeIfNeeded()

        guard let table = (controller.view.subviews.first as? NSScrollView)?
            .documentView as? OutlineTableView
        else { throw XCTSkip("no table") }
        return (controller, table)
    }

    private func hoveredRows(in table: OutlineTableView) -> [Int] {
        var rows: [Int] = []
        table.enumerateAvailableRowViews { view, index in
            if (view as? OutlineRowView)?.isHovered == true { rows.append(index) }
        }
        return rows.sorted()
    }

    func testStrayHoverStatesAreCleared() throws {
        let (_, table) = try outline()
        // Whatever put them there — a missed `mouseExited`, a recycled row — a refresh has to
        // leave at most the row actually under the pointer.
        for row in [2, 4, 6] {
            (table.rowView(atRow: row, makeIfNecessary: true) as? OutlineRowView)?.isHovered = true
        }
        XCTAssertEqual(hoveredRows(in: table).count, 3, "test could not set up the stray state")

        table.refreshHover()
        XCTAssertLessThanOrEqual(hoveredRows(in: table).count, 1,
                                 "more than one row is showing the hover pill")
    }

    /// Scrolling re-derives hover, so a row that moves out from under the pointer gives it up.
    func testScrollingDoesNotLeaveHoverBehind() throws {
        let (_, table) = try outline()
        (table.rowView(atRow: 3, makeIfNecessary: true) as? OutlineRowView)?.isHovered = true
        table.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 120))
        table.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(hoveredRows(in: table).count, 1,
                                 "a hovered row survived a scroll")
    }
}
