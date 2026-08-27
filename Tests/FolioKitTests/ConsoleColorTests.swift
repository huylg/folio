import AppKit
import XCTest
@testable import FolioKit

/// The last leg of the journey a color makes: a command's escape sequence has become a
/// `TerminalCellStyle`, and here it has to become attributes on the text a reader actually
/// looks at. `TerminalParserTests` pins the parsing; this pins the painting.
final class ConsoleColorTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )
    private let width: CGFloat = 500

    private var savedRevealDuration: TimeInterval = 0
    private var window: TestWindow!

    override func setUp() {
        super.setUp()
        savedRevealDuration = RunOutputPanel.revealDuration
        RunOutputPanel.revealDuration = 0
    }

    override func tearDown() {
        RunOutputPanel.revealDuration = savedRevealDuration
        window = nil
        super.tearDown()
    }

    /// Folio is dark only, and a resolved color is only meaningful against a resolved
    /// appearance — `.labelColor` is near-black under Aqua and near-white under Dark Aqua.
    private var appearance: NSAppearance { NSAppearance(named: .darkAqua)! }

    private func lines(_ code: String) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [.font: metrics.ramp.mono()])
    }

    private func click(_ button: NSButton) {
        _ = button.target?.perform(button.action, with: button)
    }

    /// A card in a real window, laid out, with one run in flight — the state a console is in
    /// while the pty is streaming into it.
    private func runningConsole(_ transcript: TerminalSnapshot) throws -> NSTextView {
        let host = RecordingHost(metrics: metrics)
        let card = CodeComponentView(label: "bash", source: "echo hi", language: "bash",
                                     lines: lines("echo hi"), metrics: metrics, host: host)
        window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = card
        window.orderBack(nil)

        click(try XCTUnwrap(card.runButton))
        host.emitOutput(transcript)

        card.frame = NSRect(x: 0, y: 0, width: width,
                            height: card.sizeThatFits(width: width).height)
        card.layoutSubtreeIfNeeded()

        let panel = try XCTUnwrap(card.runPanels.first, "the run opened no console")
        let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        return try XCTUnwrap(scroll.documentView as? NSTextView)
    }

    /// One fixture through a real parser, so these tests are fed exactly what a pty would
    /// deliver rather than a snapshot hand-built to suit them.
    private func parse(_ fixture: String) -> TerminalSnapshot {
        let parser = TerminalParser()
        parser.feed(fixture.replacingOccurrences(of: "\n", with: "\r\n"))
        return parser.snapshot()
    }

    private func srgb(_ color: NSColor) throws -> (r: CGFloat, g: CGFloat,
                                                   b: CGFloat, a: CGFloat) {
        try XCTUnwrap(color.components(in: appearance),
                      "a color that cannot be resolved to sRGB cannot be compared")
    }

    func testColorsReachTheRenderedText() throws {
        let text = try runningConsole(parse("\u{1B}[31merror\u{1B}[0m  ok\n"))
        let rendered = text.attributedString()
        XCTAssertTrue(rendered.string.hasPrefix("error  ok"),
                      "the text itself must be untouched by the coloring")

        var range = NSRange(location: 0, length: 0)
        let color = try XCTUnwrap(
            rendered.attribute(.foregroundColor, at: 0, effectiveRange: &range) as? NSColor,
            "the first word must carry a foreground color of its own")
        XCTAssertEqual(try srgb(color).r, try srgb(Ink.terminal(1)).r, accuracy: 0.001,
                       "SGR 31 must paint the palette's red, not the console's body ink")
        XCTAssertEqual(range, NSRange(location: 0, length: 5),
                       "the color must stop exactly where the reset did — at 'error', not "
                           + "into the plain text after it")

        let after = try XCTUnwrap(
            rendered.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(try srgb(after).r, try srgb(Ink.body).r, accuracy: 0.001,
                       "text after the reset must go back to the console's own ink")
    }

    func testTruecolorAndBackgroundsAreBothPainted() throws {
        let text = try runningConsole(parse("\u{1B}[48;2;40;80;200m    \u{1B}[0m\n"))
        let rendered = text.attributedString()
        let background = try XCTUnwrap(
            rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
            "a background color must be painted, not dropped for want of a foreground")
        let components = try srgb(background)
        XCTAssertEqual(components.r, 40.0 / 255, accuracy: 0.005)
        XCTAssertEqual(components.g, 80.0 / 255, accuracy: 0.005)
        XCTAssertEqual(components.b, 200.0 / 255, accuracy: 0.005)
    }

    /// The bug this exists to prevent: swapping before the defaults are resolved hands the
    /// text `.default` for its color and leaves the background unpainted, so the reversed word
    /// is drawn in the color it is sitting on — a hole where the emphasis should be.
    func testInverseProducesTwoConcreteColorsRatherThanAHole() throws {
        let text = try runningConsole(parse("\u{1B}[7mreverse\u{1B}[0m\n"))
        let rendered = text.attributedString()

        let foreground = try XCTUnwrap(
            rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let background = try XCTUnwrap(
            rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
            "reversed text must paint its background — that is the whole of the effect")

        let front = try srgb(foreground)
        let back = try srgb(background)
        XCTAssertGreaterThan(
            abs(front.r - back.r) + abs(front.g - back.g) + abs(front.b - back.b), 0.2,
            "the two colors must actually differ, or the word is invisible")

        // With no colors named at all, reversing swaps the console's own pair: dark text on
        // the light body ink.
        let bodyInk = try srgb(Ink.body)
        XCTAssertEqual(back.r, bodyInk.r, accuracy: 0.001,
                       "the background must become what the foreground would have been")
        XCTAssertLessThan(front.r, back.r,
                          "and the text must become the darker of the two, being the surface "
                              + "it was sitting on")
    }

    func testBoldAndItalicKeepTheirColumns() throws {
        let text = try runningConsole(
            parse("\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m plain\n"))
        let rendered = text.attributedString()

        let bold = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let plain = try XCTUnwrap(rendered.attribute(.font, at: 13,
                                                     effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold),
                      "SGR 1 must actually reach the face, not only the color")
        XCTAssertFalse(plain.fontDescriptor.symbolicTraits.contains(.bold))

        // The reason the advance is taken from the regular face: a bold word measured against
        // its own face is wider, and every column after it on the line would shift.
        let boldWidth = ("0" as NSString).size(withAttributes: [.font: bold]).width
        let plainWidth = ("0" as NSString).size(withAttributes: [.font: plain]).width
        XCTAssertEqual(boldWidth, plainWidth, accuracy: 0.01,
                       "a bold run must occupy exactly as many columns as a plain one")
    }

    func testUnderlineAndStrikethroughSurviveIntoTheText() throws {
        let text = try runningConsole(parse("\u{1B}[4munder\u{1B}[0m\u{1B}[9mgone\u{1B}[0m\n"))
        let rendered = text.attributedString()
        XCTAssertEqual(rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertNil(rendered.attribute(.underlineStyle, at: 6, effectiveRange: nil),
                     "the reset must lift the underline before the next word")
        XCTAssertEqual(
            rendered.attribute(.strikethroughStyle, at: 6, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue)
    }

    /// A finished run is rendered from `Output.transcript`, not re-derived from its text, so
    /// the colors have to survive the hand-off from the live view to the logged one.
    func testTheLoggedResultKeepsTheColorsTheLiveViewShowed() throws {
        let transcript = parse("\u{1B}[32mok\u{1B}[0m\n").trimmingBlankEdges()
        let rendered = RunOutputPanel.outputText(
            ProcessRunner.Output(status: 0, outputText: transcript.plainText, errorText: "",
                                 transcript: transcript),
            metrics: metrics)
        let color = try XCTUnwrap(
            rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(try srgb(color).g, try srgb(Ink.terminal(2)).g, accuracy: 0.001,
                       "the settled console must not flatten what the live one showed")
    }

    /// A running console shows the lines the command printed and nothing else. The cursor is
    /// parked on a fresh row after every newline, and drawing that row hangs a blank line off
    /// the foot of the console — a gap that reads as broken padding.
    func testTheCursorRowIsNotDrawnAsABlankLastLine() throws {
        let text = try runningConsole(parse("tick 1\ntick 2\n"))
        XCTAssertEqual(text.attributedString().string, "tick 1\ntick 2",
                       "the row the next line will go on must not be rendered as a line")
    }

    /// Only the cursor's row goes: a blank line the command actually printed is output, and
    /// the console is the log, not a tidied-up version of it.
    func testABlankLineTheCommandPrintedSurvives() throws {
        let text = try runningConsole(parse("tick 1\n\ntick 2\n"))
        XCTAssertEqual(text.attributedString().string, "tick 1\n\ntick 2")
    }

    /// The live view and the logged one must agree on how many lines there are, or the console
    /// jumps by a row at the moment the command exits.
    func testTheConsoleDoesNotChangeHeightWhenTheRunFinishes() {
        let transcript = parse("tick 1\ntick 2\n")
        let running = RunOutputPanel.settledHeight(
            bodyText: RunOutputPanel.liveText(transcript, metrics: metrics),
            width: width, metrics: metrics)
        let finished = RunOutputPanel.settledHeight(
            bodyText: RunOutputPanel.outputText(
                ProcessRunner.Output(status: 0, outputText: transcript.plainText, errorText: "",
                                     transcript: transcript.trimmingBlankEdges()),
                metrics: metrics),
            width: width, metrics: metrics)
        XCTAssertEqual(running, finished, accuracy: 0.01,
                       "settling into the logged result must not resize the console")
    }

    /// The non-pty paths — `UpdateInstaller`, and any host that fabricates a result — carry no
    /// transcript at all, and must still render as they always did.
    func testAResultWithNoTranscriptStillRendersItsText() throws {
        let rendered = RunOutputPanel.outputText(
            ProcessRunner.Output(status: 3, outputText: "out", errorText: "bad"),
            metrics: metrics)
        XCTAssertEqual(rendered.string, "exit 3\nout\nbad")
    }
}
