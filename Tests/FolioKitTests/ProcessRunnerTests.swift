import XCTest
@testable import FolioKit

final class ProcessRunnerTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    func testRunsInTheGivenWorkingDirectory() {
        let result = ProcessRunner.runShell("pwd", at: scratch)
        XCTAssertEqual(result.status, 0)
        // /var is a symlink to /private/var, and the kernel reports the resolved cwd.
        XCTAssertEqual(URL(fileURLWithPath: result.outputText).resolvingSymlinksInPath().path,
                       scratch.resolvingSymlinksInPath().path)
    }

    func testSeparatesStreamsAndReportsExitStatus() {
        let result = ProcessRunner.runShell("echo out; echo err 1>&2; exit 3", at: scratch)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.outputText, "out")
        XCTAssertEqual(result.errorText, "err")
    }

    func testMissingWorkingDirectoryFailsWithoutThrowing() {
        let gone = scratch.appendingPathComponent("gone")
        let result = ProcessRunner.runShell("pwd", at: gone)
        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(result.errorText.isEmpty)
    }

    // MARK: Streaming on a pty

    private func stream(_ command: String,
                        timeout: TimeInterval = 10) -> (chunks: [TerminalSnapshot],
                                                        result: ProcessRunner.Output?) {
        var chunks: [TerminalSnapshot] = []
        var result: ProcessRunner.Output?
        ProcessRunner.streamShell(command, at: scratch,
                                  onOutput: { chunks.append($0) },
                                  completion: { result = $0 })
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return (chunks, result)
    }

    func testStreamShellDeliversOutputLiveAndLogsTheResult() throws {
        let (chunks, result) = stream("printf 'a\\nb\\n'")
        let final = try XCTUnwrap(result)
        XCTAssertEqual(final.status, 0)
        XCTAssertEqual(final.outputText, "a\nb", "the logged transcript must be normalized")
        XCTAssertEqual(final.errorText, "", "a pty merges the streams by nature")
        XCTAssertFalse(chunks.isEmpty, "output must arrive before the command exits")
        XCTAssertTrue(try XCTUnwrap(chunks.last).plainText.contains("a\nb"),
                      "each chunk is the whole transcript so far")
    }

    func testStreamShellMergesStderrAndReportsExitStatus() throws {
        let (_, result) = stream("echo err 1>&2; exit 3")
        let final = try XCTUnwrap(result)
        XCTAssertEqual(final.status, 3)
        XCTAssertEqual(final.outputText, "err",
                       "stderr lands in the transcript — a terminal has one stream")
    }

    func testStreamShellRunsInTheGivenWorkingDirectory() throws {
        let (_, result) = stream("pwd")
        let final = try XCTUnwrap(result)
        XCTAssertEqual(URL(fileURLWithPath: final.outputText).resolvingSymlinksInPath().path,
                       scratch.resolvingSymlinksInPath().path)
    }

    /// A pty opened without a winsize reports 0×0, and tty-aware tools truncate every log
    /// line to the columns the terminal claims. The console's pty must report a real size.
    func testStreamShellReportsARealTerminalSize() throws {
        let (_, result) = stream("stty size")
        let final = try XCTUnwrap(result)
        XCTAssertEqual(final.outputText,
                       "\(ProcessRunner.ptyRows) \(ProcessRunner.ptyColumns)",
                       "a 0×0 terminal makes tools truncate their output")
    }

    func testStreamShellKeepsAHugeTranscriptWhole() throws {
        let (chunks, result) = stream("seq 1 20000; echo END-MARKER", timeout: 60)
        let final = try XCTUnwrap(result)
        XCTAssertEqual(final.status, 0)
        XCTAssertTrue(final.outputText.hasPrefix("1\n2\n"),
                      "the head of a long log must survive")
        XCTAssertTrue(final.outputText.hasSuffix("END-MARKER"),
                      "the tail of a long log must survive")
        XCTAssertEqual(final.outputText.components(separatedBy: "\n").count, 20001)
        XCTAssertTrue(try XCTUnwrap(chunks.last).plainText.contains("END-MARKER") ||
                      final.outputText.hasSuffix("END-MARKER"))
    }

    /// The pty is what makes color happen at all: `TERM=dumb` — what this used to claim —
    /// tells every honest tool to suppress it. The transcript that comes back must therefore
    /// be styled, not stripped.
    func testStreamShellKeepsTheColorsACommandAsksFor() throws {
        let (_, result) = stream("printf '\\033[31mred\\033[0m plain\\n'")
        let final = try XCTUnwrap(result)
        XCTAssertEqual(final.outputText, "red plain",
                       "the escape codes themselves must not reach the reader")
        let runs = try XCTUnwrap(final.transcript.lines.first).runs
        XCTAssertEqual(runs.map(\.text), ["red", " plain"],
                       "the colored word and the plain one are separate runs")
        XCTAssertEqual(runs[0].style.foreground, .palette(1), "red is palette slot 1")
        XCTAssertEqual(runs[1].style.foreground, .default,
                       "the reset must return the rest of the line to the console's own ink")
    }
}

/// The parser is fed bytes directly here rather than through a pty, which is the only way to
/// pin the awkward cases: a sequence split mid-escape, a UTF-8 character split mid-character,
/// an OSC nobody should ever see.
final class TerminalParserTests: XCTestCase {

    /// Runs one fixture through a fresh parser.
    ///
    /// The `\n` translation is not a convenience — it is the tty's own line discipline. ONLCR
    /// turns a program's bare `\n` into `\r\n` before the pty master ever sees it, and a line
    /// feed on its own moves *down* without returning to column zero. Without this a fixture
    /// written the way anyone would write it reads back as a staircase, and the test would be
    /// pinning the wrong thing.
    private func parse(_ fixture: String, translatingNewlines: Bool = true) -> TerminalSnapshot {
        let parser = TerminalParser()
        parser.feed(translatingNewlines
                    ? fixture.replacingOccurrences(of: "\n", with: "\r\n")
                    : fixture)
        return parser.snapshot()
    }

    private func line(_ snapshot: TerminalSnapshot, _ index: Int) throws -> TerminalLine {
        try XCTUnwrap(snapshot.lines.indices.contains(index) ? snapshot.lines[index] : nil,
                      "the transcript has only \(snapshot.lines.count) lines")
    }

    // MARK: Color becomes style, not text

    func testColorBecomesStyleRatherThanText() throws {
        let snapshot = parse("\u{1B}[31mred\u{1B}[0m plain\n")
        XCTAssertEqual(snapshot.plainText, "red plain\n",
                       "no part of an escape sequence may survive as text")
        let runs = try line(snapshot, 0).runs
        XCTAssertEqual(runs.map(\.text), ["red", " plain"])
        XCTAssertEqual(runs[0].style.foreground, .palette(1))
        XCTAssertEqual(runs[1].style, .plain, "SGR 0 clears every attribute, not just color")
    }

    func testBrightForegroundAndBackgroundUseTheUpperSlots() throws {
        let runs = try line(parse("\u{1B}[91;104mloud\u{1B}[0m"), 0).runs
        XCTAssertEqual(runs[0].style.foreground, .palette(9),
                       "90–97 are the bright half of the 16-color set")
        XCTAssertEqual(runs[0].style.background, .palette(12))
    }

    func testTwoHundredFiftySixColorIndexIsCarriedThrough() throws {
        let runs = try line(parse("\u{1B}[38;5;208mamber\u{1B}[0m"), 0).runs
        XCTAssertEqual(runs[0].style.foreground, .palette(208),
                       "a cube index must survive as an index, not be flattened to a name")
    }

    func testTruecolorIsCarriedThroughAsItsChannels() throws {
        let runs = try line(parse("\u{1B}[38;2;40;80;200mexact\u{1B}[0m"), 0).runs
        XCTAssertEqual(runs[0].style.foreground, .rgb(40, 80, 200))
    }

    func testBackgroundAndAttributesEachSurviveTheirOwnReset() throws {
        let snapshot = parse("\u{1B}[1mbold\u{1B}[22m \u{1B}[4munder\u{1B}[24m"
                             + " \u{1B}[42mgreen\u{1B}[49m done")
        let runs = try line(snapshot, 0).runs
        XCTAssertEqual(runs.map(\.text), ["bold", " ", "under", " ", "green", " done"])
        XCTAssertTrue(runs[0].style.bold)
        XCTAssertTrue(runs[2].style.underline)
        XCTAssertEqual(runs[4].style.background, .palette(2))
        XCTAssertEqual(runs[5].style, .plain,
                       "each attribute's own reset must leave the others alone — and by the "
                           + "end of this line every one of them has been reset")
    }

    // MARK: Cursor movement within a line

    func testCarriageReturnRewritesItsLine() throws {
        let snapshot = parse("10%\r55%\r100%\ndone")
        XCTAssertEqual(snapshot.plainText, "100%\ndone",
                       "a progress bar's hundred repaints are one line, not a hundred")
    }

    func testARewriteShorterThanWhatItOverwritesLeavesTheTailBehind() {
        // Exactly what a terminal shows: the rewrite covers the first four columns and the
        // rest of the old line is still standing. This is why tools pad their final line with
        // spaces — and why `\u{1B}[K` exists for the ones that would rather not count.
        XCTAssertEqual(parse("working\rdone").plainText, "doneing")
    }

    func testCRLFIsOneLineBreak() {
        XCTAssertEqual(parse("a\r\nb\r\n", translatingNewlines: false).plainText, "a\nb\n",
                       "a pty's CRLF pair must not produce a blank line between rows")
    }

    func testEraseToEndOfLineClearsWhatARewriteWouldHaveLeft() {
        XCTAssertEqual(parse("working\r\u{1B}[Kdone").plainText, "done",
                       "erase-to-end-of-line is how a tool clears a longer previous line")
        // The same fixture without the erase is the case above: correct `\r` handling is what
        // makes the erase a no-op in the common case, where the rewrite is at least as long.
        XCTAssertEqual(parse("10%\r\u{1B}[K100%").plainText, "100%")
    }

    func testEraseWholeLineEmptiesIt() {
        XCTAssertEqual(parse("kept\ngone\u{1B}[2K").plainText, "kept\n")
    }

    // MARK: Sequences that must vanish

    func testOSCTitleIsSwallowedWhole() {
        XCTAssertEqual(parse("\u{1B}]0;a title\u{07}text").plainText, "text",
                       "a window title is not output, and its payload is not text")
        XCTAssertEqual(parse("\u{1B}]0;a title\u{1B}\\text").plainText, "text",
                       "the two-byte ST terminates an OSC just as BEL does")
    }

    func testUnhandledSequencesLeaveNothingBehind() {
        XCTAssertEqual(parse("a\u{1B}[2Ab\u{1B}[?25lc\u{1B}(Bd").plainText, "abcd",
                       "cursor motion, private modes, and charset selection are all dropped "
                           + "silently rather than printed")
    }

    // MARK: Split across reads

    func testASequenceSplitAcrossTwoWritesStillApplies() throws {
        let parser = TerminalParser()
        parser.feed("plain \u{1B}[3")
        XCTAssertEqual(parser.snapshot().plainText, "plain ",
                       "the half-arrived escape must not show as text in the meantime")
        parser.feed("1mred")
        let runs = try line(parser.snapshot(), 0).runs
        XCTAssertEqual(runs.map(\.text), ["plain ", "red"])
        XCTAssertEqual(runs[1].style.foreground, .palette(1),
                       "a sequence that arrived in two reads must still be one sequence")
    }

    func testAUTF8CharacterSplitAcrossTwoWritesIsNotMangled() {
        let parser = TerminalParser()
        let bytes = Array("héllo".utf8)
        // The split lands between the two bytes of "é".
        parser.feed(bytes[0..<2])
        XCTAssertEqual(parser.snapshot().plainText, "h",
                       "half a character must be held back, not decoded as a replacement")
        parser.feed(bytes[2...])
        XCTAssertEqual(parser.snapshot().plainText, "héllo")
    }

    // MARK: Reading the snapshot

    func testPlainTextConstructorRoundTripsThroughPlainText() {
        let snapshot = TerminalSnapshot.plainText("one\ntwo\n")
        XCTAssertEqual(snapshot.plainText, "one\ntwo\n")
        XCTAssertTrue(snapshot.lines.allSatisfy { $0.runs.allSatisfy { $0.style.isPlain } },
                      "a transcript with no parser behind it carries no styling to render")
    }

    func testTrimmingBlankEdgesMatchesWholeStringTrimming() {
        let snapshot = parse("\n\n  hello  \n\n").trimmingBlankEdges()
        XCTAssertEqual(snapshot.plainText, "hello",
                       "the logged result is trimmed exactly as the string always was")
        XCTAssertTrue(parse("\n\n").trimmingBlankEdges().isEmpty,
                      "a command that printed nothing but newlines printed nothing")
    }

    func testStyleSurvivesTrimming() throws {
        let snapshot = parse("\n\u{1B}[32mok\u{1B}[0m\n").trimmingBlankEdges()
        let runs = try line(snapshot, 0).runs
        XCTAssertEqual(runs.map(\.text), ["ok"])
        XCTAssertEqual(runs[0].style.foreground, .palette(2),
                       "trimming the edges must not flatten what is left")
    }
}
