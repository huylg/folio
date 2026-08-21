import AppKit

/// A Markdown table.
///
/// Deliberately **not** `NSTextTable`: Apple names it as a trigger that silently reverts the
/// whole text view to TextKit 1, which would destroy every view-based attachment in the
/// document.
///
/// Also deliberately not an `NSGridView`. Attachment views are created and destroyed as
/// fragments enter and leave the viewport, and a grid built while its host still had a
/// placeholder height collapsed its body rows to zero and never recovered. Drawing the cells
/// directly makes the geometry deterministic, and — more importantly — makes it *identical* to
/// the geometry `attachmentBounds` measured, so the reserved height always matches what is
/// drawn.
public final class TableBlockView: BlockCardView {

    private let spec: TableSpec
    private let metrics: DocumentMetrics
    private weak var host: BlockHost?

    static let cellPadding = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

    /// Cached layout, recomputed only when the width changes.
    private struct Geometry {
        let width: CGFloat
        let columns: [CGFloat]
        let rowHeights: [CGFloat]

        var rowOrigins: [CGFloat] {
            var origins: [CGFloat] = []
            var y: CGFloat = 0
            for height in rowHeights { origins.append(y); y += height }
            return origins
        }
        var columnOrigins: [CGFloat] {
            var origins: [CGFloat] = []
            var x: CGFloat = 0
            for width in columns { origins.append(x); x += width }
            return origins
        }
    }
    private var cachedGeometry: Geometry?

    /// Effective alignment per column, and which columns hold numbers.
    private let alignments: [NSTextAlignment]
    private let numericColumns: Set<Int>

    /// Column widths imposed from outside, so the pages of a split table line up.
    ///
    /// A fragment holds only some of the rows, and widths derived from those rows alone would
    /// differ from page to page — the same table would change shape as the reader turned the
    /// page. The splitter measures the whole table once and hands the result to every fragment.
    private let fixedColumnWidths: [CGFloat]?

    public init(spec: TableSpec, metrics: DocumentMetrics, host: BlockHost?,
                columnWidths: [CGFloat]? = nil) {
        self.spec = spec
        self.metrics = metrics
        self.host = host
        self.fixedColumnWidths = columnWidths
        let numeric = Self.numericColumns(in: spec)
        self.numericColumns = numeric
        self.alignments = (0..<max(1, spec.columnCount)).map { column in
            let declared = spec.alignments.indices.contains(column)
                ? spec.alignments[column] : .natural
            // `.natural` means the author wrote no colons. A column of numbers reads far better
            // right-aligned — that is how a reader compares them — so it is the default there,
            // while an explicit alignment is always obeyed.
            guard declared == .natural else { return declared }
            return numeric.contains(column) ? .right : .natural
        }
        super.init(frame: .zero)

        setAccessibilityRole(.table)
        setAccessibilityLabel(
            "Table, \(spec.rows.count) rows, \(spec.columnCount) columns. "
                + spec.tabSeparated.replacingOccurrences(of: "\t", with: ", ")
        )
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    /// What this view actually renders, so a test can check a page of a split table matches the
    /// slot it was placed in.
    var renderedSpec: TableSpec { spec }
    var imposedColumnWidths: [CGFloat]? { fixedColumnWidths }

    // MARK: Geometry

    private func geometry(for width: CGFloat) -> Geometry {
        if let cachedGeometry, cachedGeometry.width == width { return cachedGeometry }
        let columns = fixedColumnWidths
            ?? Self.columnWidths(spec: spec, width: width, metrics: metrics)
        var heights = [Self.rowHeight(cells: spec.header, columnWidths: columns, metrics: metrics)]
        for row in spec.rows {
            heights.append(Self.rowHeight(cells: row, columnWidths: columns, metrics: metrics))
        }
        let result = Geometry(width: width, columns: columns, rowHeights: heights)
        cachedGeometry = result
        return result
    }

    /// Column widths distributed in proportion to each column's natural content width.
    ///
    /// Equal columns break long text cells mid-word while leaving numeric columns half empty.
    /// One function serves both the drawing and the height calculation, which is what keeps the
    /// two from disagreeing.
    static func columnWidths(
        spec: TableSpec, width: CGFloat, metrics: DocumentMetrics
    ) -> [CGFloat] {
        let columns = max(1, spec.columnCount)
        let chrome = CGFloat(columns) * (cellPadding.left + cellPadding.right)
        let available = max(CGFloat(columns) * 8, width - chrome)

        var natural = [CGFloat](repeating: 0, count: columns)
        var minimum = [CGFloat](repeating: 0, count: columns)
        for cells in [spec.header] + spec.rows {
            for (index, cell) in cells.enumerated() where index < columns {
                let text = cell.text
                guard text.length > 0 else { continue }
                natural[index] = max(natural[index], text.size().width)
                let attributes = text.attributes(at: 0, effectiveRange: nil)
                // Floor each column at its longest single word so nothing breaks mid-word.
                for word in text.string.split(whereSeparator: { $0.isWhitespace }) {
                    let size = (String(word) as NSString).size(withAttributes: attributes)
                    minimum[index] = max(minimum[index], size.width)
                }
            }
        }

        let totalNatural = natural.reduce(0, +)
        guard totalNatural > 0 else {
            return [CGFloat](repeating: width / CGFloat(columns), count: columns)
        }

        if totalNatural <= available {
            // Everything fits: hand out the slack proportionally so the table fills the card.
            let slack = available - totalNatural
            return natural.map {
                $0 + slack * ($0 / totalNatural) + cellPadding.left + cellPadding.right
            }
        }

        // Too wide: shrink proportionally, but never below the longest word.
        var widths = natural.map { $0 * available / totalNatural }
        for index in widths.indices { widths[index] = max(widths[index], minimum[index]) }
        let overshoot = widths.reduce(0, +) - available
        if overshoot > 0 {
            let slackPerColumn = widths.indices.map { max(0, widths[$0] - minimum[$0]) }
            let totalSlack = slackPerColumn.reduce(0, +)
            if totalSlack > 0 {
                for index in widths.indices {
                    widths[index] -= overshoot * (slackPerColumn[index] / totalSlack)
                }
            }
        }
        return widths.map { $0 + cellPadding.left + cellPadding.right }
    }

    /// Columns whose body cells are all numbers.
    ///
    /// Deliberately generous about what a number looks like: thousands separators, decimals,
    /// a trailing unit like `×` or `%`, a leading sign. A column of "1.00×", "98.4", "1,640" is
    /// a column of numbers to a reader, whatever a stricter parser would say.
    static func numericColumns(in spec: TableSpec) -> Set<Int> {
        var result: Set<Int> = []
        for column in 0..<max(1, spec.columnCount) {
            var sawOne = false
            var allNumeric = true
            for row in spec.rows where column < row.count {
                let text = row[column].text.string.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                sawOne = true
                if !isNumeric(text) { allNumeric = false; break }
            }
            if sawOne, allNumeric { result.insert(column) }
        }
        return result
    }

    static func isNumeric(_ text: String) -> Bool {
        let core = text.trimmingCharacters(
            in: CharacterSet(charactersIn: "+-±%×x*°$€£¥ \u{00a0}")
        )
        guard !core.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.,:/–—-eE")
        guard core.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // At least one digit, or "-" alone would read as a number.
        return core.contains { $0.isNumber }
    }

    /// The same font with tabular figures, so digits in a column line up.
    static func tabularFigures(_ font: NSFont) -> NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Any]] = [[
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static func lineHeight(metrics: DocumentMetrics) -> CGFloat {
        let font = metrics.ramp.callout()
        return (font.ascender - font.descender + font.leading).rounded()
    }

    /// A row with a single cell spans the table.
    ///
    /// Markdown tables in the wild use one-cell rows as sub-headings — "Part I." above a run of
    /// chapters — and squeezing that into the first column while the rest of the row sits empty
    /// wraps a title that had room to spare.
    static func spans(_ cells: [TableSpec.Cell], columnCount: Int) -> Bool {
        cells.count == 1 && columnCount > 1
    }

    /// Measured rather than assumed: at a narrow measure a header cell can wrap to two lines,
    /// and a flat row height left the last row hanging outside the card.
    static func rowHeight(
        cells: [TableSpec.Cell], columnWidths: [CGFloat], metrics: DocumentMetrics
    ) -> CGFloat {
        let line = lineHeight(metrics: metrics)
        var tallest = line
        let spanning = spans(cells, columnCount: columnWidths.count)
        for (index, cell) in cells.enumerated() where index < columnWidths.count {
            guard cell.text.length > 0 else { continue }
            let columnWidth = spanning ? columnWidths.reduce(0, +) : columnWidths[index]
            let available = max(1, columnWidth - cellPadding.left - cellPadding.right)
            let bounds = cell.text.boundingRect(
                with: NSSize(width: available, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            tallest = max(tallest, max(line, bounds.height.rounded(.up)))
        }
        return (tallest + cellPadding.top + cellPadding.bottom).rounded()
    }

    /// Analytic, so the stack can measure a table without building it.
    public static func height(spec: TableSpec, width: CGFloat, metrics: DocumentMetrics,
                              columnWidths fixed: [CGFloat]? = nil) -> CGFloat {
        let columns = fixed ?? columnWidths(spec: spec, width: width, metrics: metrics)
        var total = rowHeight(cells: spec.header, columnWidths: columns, metrics: metrics)
        for row in spec.rows {
            total += rowHeight(cells: row, columnWidths: columns, metrics: metrics)
        }
        return total
    }

    /// The header's height and each body row's height, for a splitter deciding where to break.
    public static func rowHeights(spec: TableSpec, width: CGFloat, metrics: DocumentMetrics)
        -> (columns: [CGFloat], header: CGFloat, rows: [CGFloat]) {
        let columns = columnWidths(spec: spec, width: width, metrics: metrics)
        return (columns,
                rowHeight(cells: spec.header, columnWidths: columns, metrics: metrics),
                spec.rows.map { rowHeight(cells: $0, columnWidths: columns, metrics: metrics) })
    }

    public override func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width, height: Self.height(spec: spec, width: width, metrics: metrics))
    }

    // MARK: Drawing

    public override func drawCardContents(in rect: NSRect) {
        guard spec.columnCount > 0, rect.width > 0 else { return }
        let layout = geometry(for: rect.width)
        let rowOrigins = layout.rowOrigins
        let columnOrigins = layout.columnOrigins
        let hairline = CardChrome.hairlineWidth(in: self)

        // Header band, then a stripe on every other body row. A hairline between every row
        // turned a long table into a ledger; a band is quieter to scan down, and the only rule
        // left is the one that actually separates something — the header from the body.
        Ink.tableHeaderFill.setFill()
        NSRect(x: 0, y: 0, width: rect.width, height: layout.rowHeights[0]).fill()

        Ink.tableStripe.setFill()
        for rowIndex in stride(from: 2, to: layout.rowHeights.count, by: 2) {
            NSRect(x: 0, y: rowOrigins[rowIndex], width: rect.width,
                   height: layout.rowHeights[rowIndex]).fill()
        }

        Ink.hairline.setFill()
        NSRect(x: 0, y: layout.rowHeights[0] - hairline,
               width: rect.width, height: hairline).fill()

        for (rowIndex, cells) in ([spec.header] + spec.rows).enumerated() {
            let y = rowOrigins[rowIndex]
            let height = layout.rowHeights[rowIndex]
            let spanning = Self.spans(cells, columnCount: layout.columns.count)
            for (columnIndex, cell) in cells.enumerated()
            where columnIndex < layout.columns.count {
                guard cell.text.length > 0 else { continue }
                let columnWidth = spanning
                    ? layout.columns.reduce(0, +)
                    : layout.columns[columnIndex]
                let box = NSRect(
                    x: columnOrigins[columnIndex] + Self.cellPadding.left,
                    y: y + Self.cellPadding.top,
                    width: columnWidth - Self.cellPadding.left - Self.cellPadding.right,
                    height: height - Self.cellPadding.top - Self.cellPadding.bottom
                )
                draw(cell.text, in: box, column: spanning ? nil : columnIndex)
            }
        }
    }

    /// A `nil` column means the cell spans the table, and takes the natural alignment.
    private func draw(_ text: NSAttributedString, in box: NSRect, column: Int?) {
        let styled = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: styled.length)
        let style = NSMutableParagraphStyle()
        style.alignment = column.flatMap { alignments.indices.contains($0) ? alignments[$0] : nil }
            ?? .natural
        style.lineBreakMode = .byWordWrapping
        styled.addAttribute(.paragraphStyle, value: style, range: full)

        if let column, numericColumns.contains(column) {
            // Proportional digits are different widths, so a column of numbers comes out ragged
            // however it is aligned.
            styled.enumerateAttribute(.font, in: full) { value, range, _ in
                guard let font = value as? NSFont else { return }
                styled.addAttribute(.font, value: Self.tabularFigures(font), range: range)
            }
        }
        styled.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // MARK: Links

    /// Cells are drawn rather than hosted in labels, so link clicks are hit-tested against the
    /// same geometry that drew them. Whole-cell granularity: a cell is small, and the
    /// alternative is re-running text layout on every mouse-down to find an exact glyph range.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let destination = linkDestination(at: point) {
            host?.blockRequestsOpen(destination)
            return
        }
        super.mouseDown(with: event)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard bounds.width > 0 else { return }
        let layout = geometry(for: bounds.width)
        for (rowIndex, cells) in ([spec.header] + spec.rows).enumerated() {
            for (columnIndex, cell) in cells.enumerated()
            where columnIndex < layout.columns.count {
                guard firstLink(in: cell.text) != nil else { continue }
                addCursorRect(cellRect(row: rowIndex, column: columnIndex, layout: layout),
                              cursor: .pointingHand)
            }
        }
    }

    private func cellRect(row: Int, column: Int, layout: Geometry) -> NSRect {
        NSRect(x: layout.columnOrigins[column], y: layout.rowOrigins[row],
               width: layout.columns[column], height: layout.rowHeights[row])
    }

    private func linkDestination(at point: NSPoint) -> String? {
        guard bounds.width > 0 else { return nil }
        let layout = geometry(for: bounds.width)
        for (rowIndex, cells) in ([spec.header] + spec.rows).enumerated() {
            for (columnIndex, cell) in cells.enumerated()
            where columnIndex < layout.columns.count {
                guard cellRect(row: rowIndex, column: columnIndex, layout: layout).contains(point)
                else { continue }
                return firstLink(in: cell.text)
            }
        }
        return nil
    }

    private func firstLink(in text: NSAttributedString) -> String? {
        var destination: String?
        text.enumerateAttribute(
            .link, in: NSRange(location: 0, length: text.length)
        ) { value, _, stop in
            if let value {
                destination = (value as? String)
                    ?? (value as? NSString).map(String.init)
                    ?? (value as? URL)?.absoluteString
                stop.pointee = true
            }
        }
        return destination
    }
}

/// A selectable static label that routes clicks on `.link` runs. Used for frontmatter values,
/// where the content is short and a single label behaves predictably.
public final class LinkLabel: NSTextField {
    public weak var host: BlockHost?

    public init(attributed: NSAttributedString) {
        super.init(frame: .zero)
        isEditable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isSelectable = true
        allowsEditingTextAttributes = true
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        attributedStringValue = attributed
        // Must resist down to its longest word, or a tight container breaks words mid-character.
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func mouseDown(with event: NSEvent) {
        if let destination = firstLinkDestination() {
            host?.blockRequestsOpen(destination)
            return
        }
        super.mouseDown(with: event)
    }

    private func firstLinkDestination() -> String? {
        let text = attributedStringValue
        var destination: String?
        text.enumerateAttribute(
            .link, in: NSRange(location: 0, length: text.length)
        ) { value, _, stop in
            if let value {
                destination = (value as? String)
                    ?? (value as? NSString).map(String.init)
                    ?? (value as? URL)?.absoluteString
                stop.pointee = true
            }
        }
        return destination
    }
}
