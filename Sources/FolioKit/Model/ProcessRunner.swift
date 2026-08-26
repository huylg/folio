import Foundation

/// Runs a subprocess synchronously. Both streams are captured, and both are drained: a tool
/// that fills the 64K buffer of the pipe nobody is reading blocks forever, and some tools
/// report their failures on stdout. Lifted from `UpdateInstaller`, which now forwards here.
public enum ProcessRunner {

    public struct Output {
        public let status: Int32
        public let outputText: String
        public let errorText: String

        public init(status: Int32, outputText: String, errorText: String) {
            self.status = status
            self.outputText = outputText
            self.errorText = errorText
        }
    }

    @discardableResult
    public static func run(_ path: String, _ arguments: [String],
                           currentDirectory: URL? = nil) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let errors = Pipe()
        let output = Pipe()
        process.standardError = errors
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            // Also the landing spot for a working directory that no longer exists.
            return Output(status: -1, outputText: "", errorText: error.localizedDescription)
        }
        // The concurrent drain runs on a dedicated thread, never the GCD pool: a work item
        // queued behind an exhausted pool leaves this semaphore waiting forever — seen in the
        // test suite, whose accumulated window animations park dozens of worker threads.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let drained = DispatchSemaphore(value: 0)
        Thread {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }.start()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        let outputData = box.data
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      outputText: text(of: outputData),
                      errorText: text(of: errorData))
    }

    /// One shell string via `/bin/sh -c`, so pipes, quoting, and multiple arguments all work.
    @discardableResult
    public static func runShell(_ command: String, at directory: URL) -> Output {
        run("/bin/sh", ["-c", command], currentDirectory: directory)
    }

    /// Whether a fence language names a shell whose source `runShell` can execute. The
    /// sh-family only: a `fish` block is not `/bin/sh` syntax and must not get a Run button.
    public static func isShellLanguage(_ language: String?) -> Bool {
        guard let language = language?.lowercased() else { return false }
        return ["bash", "sh", "shell", "zsh"].contains(language)
    }

    // MARK: Streaming on a pseudo-terminal

    /// Runs one shell string on a real pty and streams its output as it arrives.
    ///
    /// The pty is what makes tools behave as they do in a terminal — line-buffered output
    /// flushes per line instead of arriving in one 4K lump at exit — at the price a terminal
    /// always charges: stdout and stderr are one stream, so `Output.errorText` is empty and
    /// everything lands in `outputText`. `TERM=dumb` tells honest tools not to paint colors;
    /// the sanitizer strips the escapes of the tools that paint anyway.
    ///
    /// `onOutput` is called on the main queue with the full sanitized transcript so far —
    /// replace, don't append: whole-transcript delivery is what keeps split UTF-8 sequences
    /// and half-arrived escape codes from ever being shown. `completion` is called on the
    /// main queue once, after exit, with the final transcript and status.
    /// The size the pty reports to the child. A pty opened with no winsize reports 0×0, and
    /// tty-aware tools truncate every line to the columns the terminal claims — a zero-wide
    /// terminal truncates the whole log. Wide and tall enough that no honest tool clips.
    static let ptyColumns = 512
    static let ptyRows = 128

    public static func streamShell(_ command: String, at directory: URL,
                                   onOutput: @escaping (String) -> Void,
                                   completion: @escaping (Output) -> Void) {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: UInt16(ptyRows), ws_col: UInt16(ptyColumns),
                           ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            DispatchQueue.main.async {
                completion(Output(status: -1, outputText: "",
                                  errorText: "could not open a pseudo-terminal"))
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        // Belt and braces for tools that read the environment instead of TIOCGWINSZ.
        environment["COLUMNS"] = String(ptyColumns)
        environment["LINES"] = String(ptyRows)
        process.environment = environment
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        // A dedicated thread, never the GCD pool — the read loop blocks for the command's
        // whole lifetime.
        let thread = Thread {
            do {
                try process.run()
            } catch {
                close(master)
                close(slave)
                DispatchQueue.main.async {
                    completion(Output(status: -1, outputText: "",
                                      errorText: error.localizedDescription))
                }
                return
            }
            // The child holds its own dup of the slave; the parent's copy must go, or the
            // master never sees EOF.
            close(slave)

            var transcript = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var lastEmit = Date.distantPast
            while true {
                let count = read(master, &buffer, buffer.count)
                // 0 is EOF; -1 with EINTR is a signal poking the read — not the end.
                // Any other -1 is the EIO a pty master reports once the child side closes.
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                transcript.append(contentsOf: buffer[0..<count])
                // Coalesced: a chatty command produces thousands of chunks, and every emit
                // costs the main thread a full re-render of the transcript so far. The final
                // state never suffers — completion always carries the whole transcript.
                guard Date().timeIntervalSince(lastEmit) > 0.05 else { continue }
                lastEmit = Date()
                let text = sanitizedTranscript(String(decoding: transcript, as: UTF8.self))
                DispatchQueue.main.async { onOutput(text) }
            }
            close(master)
            process.waitUntilExit()

            let full = sanitizedTranscript(String(decoding: transcript, as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                completion(Output(status: process.terminationStatus,
                                  outputText: full, errorText: ""))
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// A pty transcript reduced to displayable text: ANSI escapes stripped, `\r\n` normalized,
    /// and a bare carriage return treated as the line-rewrite it is — a progress bar's final
    /// state survives, its hundred repaints do not.
    static func sanitizedTranscript(_ raw: String) -> String {
        var text = raw
        for pattern in [
            "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",                    // CSI … final byte
            "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",    // OSC … BEL or ST
            "\u{1B}[@-_]",                                      // bare two-byte escapes
        ] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        return text.components(separatedBy: "\n").map { line in
            guard let rewrite = line.range(of: "\r", options: .backwards) else { return line }
            return String(line[rewrite.upperBound...])
        }.joined(separator: "\n")
    }

    private static func text(of data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
