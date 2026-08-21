import AppKit
import XCTest
@testable import FolioKit

final class TagPaletteTests: XCTestCase {

    /// The document card used to assign pill colors positionally while the sidebar hashed the
    /// tag string, so the same tag rendered in two different colors. Both now go through
    /// `slot(for:)`; this pins the hash so existing users' sidebar colors do not shift.
    func testSlotIsStableAndInRange() {
        for tag in ["attention", "efficiency", "to-cite", "reviewed", "", "λ", "a very long tag name"] {
            let slot = TagPalette.slot(for: tag)
            XCTAssertTrue((0..<TagPalette.slotCount).contains(slot), "slot out of range for \(tag)")
            XCTAssertEqual(slot, TagPalette.slot(for: tag), "slot not stable for \(tag)")
        }
    }

    func testSlotIsIndependentOfOrder() {
        // Positional assignment would change when an author reorders `tags:` in frontmatter.
        let first = ["attention", "efficiency", "to-cite"].map(TagPalette.slot(for:))
        let reordered = ["to-cite", "attention", "efficiency"].map(TagPalette.slot(for:))
        XCTAssertEqual(first[0], reordered[1])
        XCTAssertEqual(first[1], reordered[2])
        XCTAssertEqual(first[2], reordered[0])
    }

    /// `blended(withFraction:of:)` returns an optional and requires matching color spaces —
    /// a real nil source. The pill helper must never fall through to nil.
    func testPillResolves() {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let pill = TagPalette.pill(for: "attention")
            XCTAssertNotNil(pill.fill.usingColorSpace(.sRGB))
            XCTAssertNotNil(pill.text.usingColorSpace(.sRGB))
        }
    }
}

final class TypeRampTests: XCTestCase {

    /// At the default text size the ramp must reproduce the published macOS values exactly:
    /// body 13, Large Title 26, Title 1 22, Title 2 17, Title 3 15, Headline 13.
    func testDefaultSizeMatchesHIGRamp() {
        let ramp = TypeRamp(family: .sansSerif, textSize: AppSettings.defaultTextSize)
        XCTAssertEqual(ramp.scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(ramp.body().pointSize, 13, accuracy: 0.5)
        XCTAssertEqual(ramp.heading(level: 1).pointSize, 26, accuracy: 0.5)
        XCTAssertEqual(ramp.heading(level: 2).pointSize, 22, accuracy: 0.5)
        XCTAssertEqual(ramp.heading(level: 3).pointSize, 17, accuracy: 0.5)
        XCTAssertEqual(ramp.heading(level: 4).pointSize, 15, accuracy: 0.5)
        XCTAssertEqual(ramp.heading(level: 5).pointSize, 13, accuracy: 0.5)
    }

    /// The HIG target is "enlarge text by at least 200 percent"; macOS has no Dynamic Type,
    /// so the app's own ⌘+ control has to reach it.
    func testMaxTextSizeIsAtLeastDoubleTheDefault() {
        XCTAssertGreaterThanOrEqual(AppSettings.maxTextSize, AppSettings.defaultTextSize * 2)
        let ramp = TypeRamp(family: .serif, textSize: AppSettings.maxTextSize)
        XCTAssertEqual(ramp.body().pointSize, 26, accuracy: 1.0)
    }

    func testHeadingRampIsMonotonic() {
        let ramp = TypeRamp(family: .serif, textSize: 13)
        let sizes = (1...6).map { ramp.heading(level: $0).pointSize }
        for (a, b) in zip(sizes, sizes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a, b, "heading ramp must not increase with level")
        }
        XCTAssertGreaterThanOrEqual(sizes[0], ramp.body().pointSize)
    }

    /// Both `withDesign(.serif)` and `NSFont(descriptor:size:)` return optionals and Apple
    /// documents no nil conditions, so the SF fallback must always produce a usable font.
    func testEveryFamilyResolvesToAFont() {
        for family in AppSettings.ReadingFont.allCases {
            let ramp = TypeRamp(family: family, textSize: 13)
            XCTAssertGreaterThan(ramp.body().pointSize, 0)
            XCTAssertGreaterThan(ramp.mono().pointSize, 0)
            XCTAssertGreaterThan(ramp.averageCharacterWidth(), 0, "\(family) advance width")
        }
    }

    /// `monospacedSystemFont` is not fixed-pitch for box-drawing or CJK unless `fixedAdvance`
    /// is applied — code blocks and raw-mode YAML both depend on columns lining up.
    func testMonoIsFixedPitch() {
        let mono = TypeRamp(family: .serif, textSize: 13).mono()
        let narrow = ("i" as NSString).size(withAttributes: [.font: mono]).width
        let wide = ("W" as NSString).size(withAttributes: [.font: mono]).width
        XCTAssertEqual(narrow, wide, accuracy: 0.01, "mono font is not fixed-advance")
    }

    func testPresentationScaleIsClamped() {
        let ramp = TypeRamp(family: .serif, textSize: AppSettings.maxTextSize, presentationScale: 4)
        XCTAssertLessThanOrEqual(ramp.body().pointSize, TypeRamp.maxBodyPointSize)
    }
}

final class DocumentMetricsTests: XCTestCase {

    /// The whole point of a character-based measure: it grows with the text size, which a
    /// fixed pixel width could not.
    func testMeasureScalesWithTextSize() {
        let small = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                    lineWidth: .comfortable, density: .airy)
        let large = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 26),
                                    lineWidth: .comfortable, density: .airy)
        XCTAssertGreaterThan(large.measure, small.measure * 1.5)
    }

    func testMeasureOrderingAcrossPresets() {
        func measure(_ width: AppSettings.LineWidth) -> CGFloat {
            DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                            lineWidth: width, density: .airy).measure
        }
        XCTAssertLessThan(measure(.narrow), measure(.comfortable))
        XCTAssertLessThan(measure(.comfortable), measure(.wide))
    }

    func testMeasureClampsToNarrowPane() {
        let metrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 26),
                                      lineWidth: .wide, density: .airy)
        let pane: CGFloat = 400
        XCTAssertLessThanOrEqual(metrics.measure(fitting: pane),
                                 pane - 2 * DocumentMetrics.minimumPadding)
        XCTAssertGreaterThanOrEqual(metrics.horizontalInset(forPaneWidth: pane),
                                    DocumentMetrics.minimumPadding)
    }

    func testHeadingsPinTheRampLineHeight() {
        let metrics = DocumentMetrics(ramp: TypeRamp(family: .sansSerif, textSize: 13),
                                      lineWidth: .comfortable, density: .airy)
        let style = metrics.paragraphStyle(for: .heading(2))
        XCTAssertEqual(style.minimumLineHeight, style.maximumLineHeight)
        XCTAssertGreaterThanOrEqual(style.maximumLineHeight, 26)
    }

    /// Per-paragraph natural alignment is what gives the HIG's RTL behavior for free.
    func testEveryParagraphStyleUsesNaturalAlignment() {
        let metrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                      lineWidth: .comfortable, density: .airy)
        let kinds: [BlockKind] = [
            .title, .heading(1), .heading(6), .meta, .paragraph, .blockQuote(depth: 1),
            .listItem(depth: 1, isLast: false), .codeLine(isFirst: true, isLast: false),
            .table, .math, .diagram, .frontmatter, .image, .caption, .thematicBreak,
        ]
        for kind in kinds {
            let style = metrics.paragraphStyle(for: kind)
            XCTAssertEqual(style.alignment, .natural, "\(kind) is not naturally aligned")
            XCTAssertEqual(style.baseWritingDirection, .natural, "\(kind) forces a direction")
        }
    }

    func testDensityDrivesProseLineHeight() {
        func multiple(_ density: AppSettings.Density) -> CGFloat {
            DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                            lineWidth: .comfortable, density: density)
                .paragraphStyle(for: .paragraph).lineHeightMultiple
        }
        XCTAssertGreaterThan(multiple(.airy), multiple(.compact))
    }

    func testNestedListsAndQuotesIndentFurther() {
        let metrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                      lineWidth: .comfortable, density: .airy)
        let shallow = metrics.paragraphStyle(for: .listItem(depth: 1, isLast: false))
        let deep = metrics.paragraphStyle(for: .listItem(depth: 3, isLast: false))
        XCTAssertGreaterThan(deep.firstLineHeadIndent, shallow.firstLineHeadIndent)
        XCTAssertGreaterThan(deep.headIndent, deep.firstLineHeadIndent, "no hanging indent")

        let q1 = metrics.paragraphStyle(for: .blockQuote(depth: 1))
        let q2 = metrics.paragraphStyle(for: .blockQuote(depth: 2))
        XCTAssertGreaterThan(q2.headIndent, q1.headIndent)
    }
}

final class SyntaxHighlighterTests: XCTestCase {

    func testTokenizesKeywordsStringsNumbersAndComments() {
        let code = """
        def route(q, k, budget):
            scores = "text" + 42
            # mask is binary
        """
        let lines = SyntaxHighlighter.tokenize(code, language: "python")
        XCTAssertEqual(lines.count, 3)

        let source = code.components(separatedBy: "\n")
        func kinds(_ i: Int) -> [SyntaxHighlighter.TokenClass] { lines[i].map(\.kind) }
        func text(_ i: Int, _ t: SyntaxHighlighter.Token) -> String { String(source[i][t.range]) }

        XCTAssertTrue(kinds(0).contains(.keyword))
        XCTAssertTrue(kinds(0).contains(.function))
        XCTAssertEqual(lines[0].first { $0.kind == .keyword }.map { text(0, $0) }, "def")
        XCTAssertEqual(lines[0].first { $0.kind == .function }.map { text(0, $0) }, "route")
        XCTAssertTrue(kinds(1).contains(.string))
        XCTAssertTrue(kinds(1).contains(.number))
        XCTAssertEqual(kinds(2), [.comment])
    }

    /// A `#` or `//` inside a string literal is not a comment. The quote-parity heuristic
    /// guards this; without it half a line of code renders grey.
    func testHashInsideStringIsNotAComment() {
        let line = #"url = "https://example.com/#anchor""#
        let tokens = SyntaxHighlighter.tokenize(line, language: "python")[0]
        XCTAssertFalse(tokens.contains { $0.kind == .comment },
                       "a '#' inside a string was treated as a comment")
    }

    func testTokenRangesAreOrderedAndNonOverlapping() {
        let code = "let x = foo(1, \"two\") // trailing"
        let tokens = SyntaxHighlighter.tokenize(code, language: "swift")[0]
        for (a, b) in zip(tokens, tokens.dropFirst()) {
            XCTAssertLessThanOrEqual(a.range.upperBound, b.range.lowerBound,
                                     "token ranges overlap or are out of order")
        }
    }

    func testUnknownLanguageProducesNoKeywords() {
        let tokens = SyntaxHighlighter.tokenize("def route(q)", language: "brainfuck")[0]
        XCTAssertFalse(tokens.contains { $0.kind == .keyword })
    }

    func testAttributedOutputIsOneParagraphPerLine() {
        let metrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                      lineWidth: .comfortable, density: .airy)
        let attributed = SyntaxHighlighter.attributed("a = 1\nb = 2\nc = 3",
                                                      language: "python", metrics: metrics)
        XCTAssertEqual(attributed.string.components(separatedBy: "\n").count, 3)

        var kinds: [BlockKind] = []
        attributed.enumerateAttribute(.folioBlockKind,
                                      in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let kind = value as? BlockKind { kinds.append(kind) }
        }
        XCTAssertEqual(kinds.first, .codeLine(isFirst: true, isLast: false))
        XCTAssertEqual(kinds.last, .codeLine(isFirst: false, isLast: true))
    }
}

/// Prose and blocks share one column, flush to the same left edge.
///
/// Regression cover for the two competing margins the old 1.35 block bleed produced: a card or
/// a code block started ~35pt left of the title and paragraphs above it.
final class BlockWidthTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )
    private let pane: CGFloat = 1000

    func testBlocksShareTheProseColumn() {
        XCTAssertEqual(metrics.blockMeasure(fitting: pane), metrics.measure, accuracy: 1)
        XCTAssertEqual(metrics.proseInset(fitting: pane), 0,
                       "prose has nothing to be inset by in a single column")
    }

    /// The whole point of the single column: a paragraph, a card, and a code block all start at
    /// the same x. Kinds with an indent of their own — quotes and list items — are excluded,
    /// since theirs is deliberate.
    func testProseAndBlocksStartAtTheSameEdge() {
        let inset = metrics.proseInset(fitting: pane)
        let kinds: [BlockKind] = [.title, .heading(2), .paragraph, .caption,
                                  .table, .math, .diagram, .frontmatter, .image]
        for kind in kinds {
            XCTAssertEqual(metrics.paragraphStyle(for: kind, proseInset: inset).firstLineHeadIndent,
                           0, accuracy: 0.5, "\(kind) should start at the column's left edge")
        }
    }

    /// Prose keeps its own measure regardless — widening blocks must not widen the text column.
    func testProseMeasureIsUnchanged() {
        let styled = metrics.paragraphStyle(for: .paragraph,
                                            proseInset: metrics.proseInset(fitting: pane))
        let block = metrics.blockMeasure(fitting: pane)
        let proseWidth = block - styled.firstLineHeadIndent + styled.tailIndent
        XCTAssertEqual(proseWidth, metrics.measure, accuracy: 2)
    }

    /// Code, tables, diagrams, equations and the frontmatter card take the full width; prose
    /// blocks do not.
    func testOnlyBlockKindsTakeTheFullWidth() {
        let full: [BlockKind] = [.codeHeader, .codeLine(isFirst: true, isLast: false),
                                 .table, .math, .diagram, .frontmatter, .image]
        let prose: [BlockKind] = [.title, .heading(2), .meta, .paragraph,
                                  .blockQuote(depth: 1), .listItem(depth: 1, isLast: false),
                                  .caption, .thematicBreak]
        for kind in full {
            XCTAssertTrue(kind.usesFullBlockWidth, "\(kind) should take the full block width")
            XCTAssertEqual(metrics.paragraphStyle(for: kind, proseInset: 40).firstLineHeadIndent,
                           metrics.paragraphStyle(for: kind, proseInset: 0).firstLineHeadIndent,
                           "\(kind) should ignore the prose inset")
        }
        for kind in prose {
            XCTAssertFalse(kind.usesFullBlockWidth, "\(kind) should keep the prose measure")
        }
    }

    /// A wrapped code line hangs past its own indentation, so the continuation cannot be
    /// mistaken for a new statement at the outer level.
    func testWrappedCodeHangsPastItsOwnIndent() {
        let flush = metrics.codeLineStyle(leadingColumns: 0)
        let indented = metrics.codeLineStyle(leadingColumns: 8)
        XCTAssertGreaterThan(indented.headIndent, flush.headIndent,
                             "an indented line's continuation must hang further right")
        XCTAssertGreaterThan(indented.headIndent, indented.firstLineHeadIndent,
                             "continuations must hang, not dedent")
    }
}
