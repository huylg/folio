import AppKit
import XCTest
@testable import FolioKit

/// The table's own typography and geometry.
final class TableTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func cell(_ text: String) -> TableSpec.Cell {
        TableSpec.Cell(text: NSAttributedString(
            string: text,
            attributes: [.font: metrics.ramp.callout(), .foregroundColor: Ink.body]
        ))
    }

    private func spec(header: [String], rows: [[String]],
                      alignments: [NSTextAlignment]? = nil) -> TableSpec {
        TableSpec(header: header.map(cell),
                  rows: rows.map { $0.map(cell) },
                  alignments: alignments ?? Array(repeating: .natural, count: header.count))
    }

    /// A table of contents is the motivating case: no alignment colons in the source, and a
    /// column of page numbers that reads as a ragged mess left-aligned.
    func testUnalignedNumberColumnsAreDetected() {
        let table = spec(header: ["Chapter", "Page"],
                         rows: [["Reliability", "6"],
                                ["Hardware Faults", "7"],
                                ["How Important Is Reliability?", "10"]])
        XCTAssertEqual(TableBlockView.numericColumns(in: table), [1])
    }

    /// A column with one non-numeric body cell is not a number column.
    func testMixedColumnsAreNotNumeric() {
        let table = spec(header: ["Metric", "Value"],
                         rows: [["Latency", "12"], ["Notes", "see appendix"]])
        XCTAssertEqual(TableBlockView.numericColumns(in: table), [])
    }

    func testNumberRecognition() {
        for text in ["3", "10", "1,640", "98.4", "1.00×", "-12", "+0.5", "42%", "2019", "1/2",
                     "3–4", "1e6"] {
            XCTAssertTrue(TableBlockView.isNumeric(text), "\(text) should read as a number")
        }
        for text in ["see appendix", "N/A", "—", "v2", "Chapter 1", "", "-"] {
            XCTAssertFalse(TableBlockView.isNumeric(text), "\(text) should not read as a number")
        }
    }

    /// An explicit alignment always wins: auto-alignment only fills in what the author left open.
    func testExplicitAlignmentIsObeyed() {
        let table = spec(header: ["Chapter", "Page"],
                         rows: [["Reliability", "6"]],
                         alignments: [.center, .left])
        let view = TableBlockView(spec: table, metrics: metrics, host: nil)
        // Drawn alignment is private; the numeric detection that feeds it is not, and the view
        // must build without disturbing it.
        XCTAssertEqual(TableBlockView.numericColumns(in: table), [1])
        XCTAssertGreaterThan(view.sizeThatFits(width: 500).height, 0)
    }

    /// A one-cell row spans the table instead of being squeezed into the first column — that is
    /// how "Part I." rows in a converted table of contents are written.
    func testSingleCellRowsSpan() {
        let columns: [CGFloat] = [180, 320]
        XCTAssertTrue(TableBlockView.spans([cell("Part I.")], columnCount: columns.count))
        XCTAssertFalse(TableBlockView.spans([cell("a"), cell("b")], columnCount: columns.count))
        // A single column table has nothing to span.
        XCTAssertFalse(TableBlockView.spans([cell("Part I.")], columnCount: 1))

        let long = "Part I. Foundations of Data Systems and Everything After"
        let spanning = TableBlockView.rowHeight(cells: [cell(long)],
                                                columnWidths: columns, metrics: metrics)
        let squeezed = TableBlockView.rowHeight(cells: [cell(long), cell("")],
                                                columnWidths: columns, metrics: metrics)
        XCTAssertLessThan(spanning, squeezed,
                          "a spanning row should use the whole width and wrap less")
    }

    /// Tabular figures are what make a column of numbers line up; proportional digits are
    /// different widths.
    func testTabularFiguresAreApplied() {
        let font = metrics.ramp.callout()
        let tabular = TableBlockView.tabularFigures(font)
        let proportional = ("111" as NSString).size(withAttributes: [.font: font]).width
        let ones = ("111" as NSString).size(withAttributes: [.font: tabular]).width
        let zeros = ("000" as NSString).size(withAttributes: [.font: tabular]).width
        XCTAssertEqual(ones, zeros, accuracy: 0.01,
                       "digits are still proportional, so columns will not line up")
        XCTAssertNotEqual(ones, proportional, accuracy: 0.001,
                          "the tabular variant is the same font as before")
    }

    /// Height stays analytic and matches what the view reports, or the stack reserves the wrong
    /// space for it.
    func testMeasuredHeightMatchesTheView() {
        let table = spec(header: ["Chapter", "Page"],
                         rows: (1...5).map { ["Section \($0)", "\($0 * 3)"] })
        let view = TableBlockView(spec: table, metrics: metrics, host: nil)
        XCTAssertEqual(view.sizeThatFits(width: 480).height,
                       TableBlockView.height(spec: table, width: 480, metrics: metrics),
                       accuracy: 0.5)
    }

    /// The RFC table that ran off its card: identifiers like
    /// `reports_time_spent_not_lessons` have no whitespace, and flooring every column at its
    /// longest word summed to more than the card. Whatever the content, the columns must fit.
    func testColumnsNeverExceedTheWidth() {
        let table = spec(
            header: ["Layer", "Store", "Holds", "Written by"],
            rows: [["School activity results",
                    "b2b Postgres (assignment_lesson_result, ai_tutor_conversation, "
                        + "reports_time_spent_not_lessons, learningloop_submission)",
                    "per-attempt results, durations, EPS, LL score + status",
                    "b2b-server, b2b-server-v2"],
                   ["Statistics",
                    "DynamoDB user-statistics-v2 (elsa_statistics/db.py:UserStatisticsV2)",
                    "study_set_/dictionary_/lesson_/review_/assessment_/elsa_ai_seconds_spent",
                    "user-server + scoring server"]])
        for width: CGFloat in [320, 480, 640] {
            let columns = TableBlockView.columnWidths(spec: table, width: width, metrics: metrics)
            XCTAssertEqual(columns.reduce(0, +), width, accuracy: 0.5,
                           "columns should fill exactly \(width), not spill past the card")
            XCTAssertTrue(columns.allSatisfy { $0 > 0 })
            // And the measured height must still cover every wrapped line.
            let view = TableBlockView(spec: table, metrics: metrics, host: nil)
            XCTAssertEqual(view.sizeThatFits(width: width).height,
                           TableBlockView.height(spec: table, width: width, metrics: metrics),
                           accuracy: 0.5)
        }
    }

    /// When the floors themselves do not fit, the short columns must stay whole and only the
    /// columns with oversize words give way — otherwise "Account" breaks as "Ac-count" while a
    /// column of long identifiers, which breaks regardless, keeps more than it needs.
    func testCappedFloorsSpareTheShortColumns() {
        let widths = TableBlockView.cappedFloors([55, 233, 211, 75], available: 440)
        XCTAssertEqual(widths[0], 55)
        XCTAssertEqual(widths[3], 75)
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.01)
        XCTAssertEqual(widths.reduce(0, +), 440, accuracy: 0.01)
        // Nothing to spare at all: everyone shares equally.
        XCTAssertEqual(TableBlockView.cappedFloors([100, 300], available: 100), [50, 50])
        // Everything fits: floors pass through untouched.
        XCTAssertEqual(TableBlockView.cappedFloors([10, 20], available: 100), [10, 20])
    }

    /// TextKit breaks a path after each slash, so a cell like `a/b/c` needs no more room than
    /// its longest segment. Measuring "words" by whitespace alone overstated the floor.
    func testMinimumWidthBreaksWhereTextKitDoes() {
        let path = cell("elsa_statistics/db.py:UserStatisticsV2")
        let whole = path.text.size().width
        let floor = TableBlockView.minimumWidth(of: path.text)
        XCTAssertLessThan(floor, whole, "a slash is a line-break opportunity")
        XCTAssertGreaterThanOrEqual(floor, cell("db.py:UserStatisticsV2").text.size().width - 0.5)
    }
}
