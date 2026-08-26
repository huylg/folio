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
                        timeout: TimeInterval = 10) -> (chunks: [String],
                                                        result: ProcessRunner.Output?) {
        var chunks: [String] = []
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
        XCTAssertTrue(try XCTUnwrap(chunks.last).contains("a\nb"),
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
        XCTAssertTrue(try XCTUnwrap(chunks.last).contains("END-MARKER") ||
                      final.outputText.hasSuffix("END-MARKER"))
    }

    func testSanitizerStripsEscapesAndCarriageReturns() {
        XCTAssertEqual(ProcessRunner.sanitizedTranscript("\u{1B}[31mred\u{1B}[0m plain"),
                       "red plain", "ANSI color sequences must not reach the console")
        XCTAssertEqual(ProcessRunner.sanitizedTranscript("a\r\nb\r\n"), "a\nb\n",
                       "a pty's CRLF pairs must normalize")
        XCTAssertEqual(ProcessRunner.sanitizedTranscript("10%\r55%\r100%\ndone"),
                       "100%\ndone",
                       "a carriage return rewrites its line, as it does on screen")
        XCTAssertEqual(ProcessRunner.sanitizedTranscript("\u{1B}]0;title\u{07}text"),
                       "text", "OSC title sequences must not reach the console")
    }
}
