import Foundation

/// One color a terminal can ask for, in the terms the escape sequence itself uses.
///
/// Deliberately not an `NSColor`. A snapshot is rendered by two surfaces at once — the reading
/// pane's console and a peek card's — at possibly different type sizes, so it must stay a value
/// with no appearance baked into it. `.default` is "whatever the surface calls text", which only
/// the renderer knows; resolving it here would freeze the theme into the transcript.
public enum TerminalColor: Hashable, Sendable {
    case `default`
    /// An index into the 256-color palette. 0–15 are the named colors, 16–231 the 6×6×6 cube,
    /// 232–255 the grey ramp.
    case palette(UInt8)
    /// A direct 24-bit color, from `38;2;r;g;b`.
    case rgb(UInt8, UInt8, UInt8)
}

/// Everything SGR can say about a stretch of text.
public struct TerminalCellStyle: Hashable, Sendable {
    public var foreground: TerminalColor = .default
    public var background: TerminalColor = .default
    /// `58;…` sets the underline's color independently of the text's. Rare, but free to carry.
    public var underlineColor: TerminalColor = .default
    public var bold = false
    public var italic = false
    public var faint = false
    public var inverse = false
    public var strikethrough = false
    public var underline = false

    public static let plain = TerminalCellStyle()

    public init() {}

    public var isPlain: Bool { self == .plain }
}

/// A stretch of text sharing one style — the unit an attributed string is built from.
public struct TerminalRun: Hashable, Sendable {
    public var text: String
    public var style: TerminalCellStyle

    public init(text: String, style: TerminalCellStyle = .plain) {
        self.text = text
        self.style = style
    }
}

/// One line of the transcript, as a terminal would have it after every carriage return,
/// overwrite, and erase has been applied.
public struct TerminalLine: Hashable, Sendable {
    public var runs: [TerminalRun]

    public init(runs: [TerminalRun] = []) {
        self.runs = runs
    }

    public static let empty = TerminalLine()

    public var plainText: String { runs.map(\.text).joined() }
    public var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }
}

/// What a terminal would be showing: the whole transcript, resolved into styled lines.
///
/// This replaces the plain `String` the console used to carry. The parser produces it, the
/// session stores it, and `RunOutputPanel` turns it into an attributed string; nothing in
/// between needs to know an escape sequence ever existed.
public struct TerminalSnapshot: Hashable, Sendable {
    public var lines: [TerminalLine]

    public init(lines: [TerminalLine] = []) {
        self.lines = lines
    }

    public static let empty = TerminalSnapshot()

    /// A snapshot with no styling at all — for the paths with no parser behind them: a
    /// non-pty result, a host that fabricates output, a test seam.
    public static func plainText(_ text: String) -> TerminalSnapshot {
        guard !text.isEmpty else { return .empty }
        return TerminalSnapshot(lines: text.components(separatedBy: "\n").map {
            TerminalLine(runs: $0.isEmpty ? [] : [TerminalRun(text: $0)])
        })
    }

    /// The transcript read as text, which is what the logged `Output.outputText` is and what
    /// every existing string assertion still compares against.
    public var plainText: String { lines.map(\.plainText).joined(separator: "\n") }

    public var isEmpty: Bool { lines.allSatisfy(\.isEmpty) }

    /// The snapshot without the empty row the cursor is parked on.
    ///
    /// Every line a command prints ends in a newline, and a newline moves the cursor onto a
    /// fresh row — so a live transcript always carries one more line than it has output, and
    /// drawing it leaves a blank row under the last line of the log. That gap reads as a
    /// mistake in the card's padding rather than as content, and it makes the console shrink
    /// by a line the moment the run finishes and the logged result is trimmed.
    ///
    /// Only the final row goes, and only when it is empty. Blank rows in the middle are output
    /// a command asked for, and so is a blank row it printed before its last line — dropping
    /// more than the one the cursor sits on would flatten `a\n\n` into `a\n`.
    public func droppingCursorLine() -> TerminalSnapshot {
        guard let last = lines.last, last.isEmpty else { return self }
        return TerminalSnapshot(lines: Array(lines.dropLast()))
    }

    /// The snapshot with blank edges removed — the exact equivalent of running
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` over `plainText`, which is what the
    /// logged result has always been trimmed by. Applied to the final transcript only: a live
    /// one keeps its trailing newline, and the renderer drops the cursor's row instead, so the
    /// two agree on how many lines there are without the model losing the terminal's state.
    public func trimmingBlankEdges() -> TerminalSnapshot {
        let blank = { (line: TerminalLine) in
            line.plainText.trimmingCharacters(in: .whitespaces).isEmpty
        }
        var kept = lines
        while let first = kept.first, blank(first) { kept.removeFirst() }
        while let last = kept.last, blank(last) { kept.removeLast() }
        guard !kept.isEmpty else { return .empty }
        // The first and last surviving lines can still carry padding at the outer edges, which
        // whole-string trimming would have taken.
        kept[0] = kept[0].trimmingLeadingWhitespace()
        kept[kept.count - 1] = kept[kept.count - 1].trimmingTrailingWhitespace()
        return TerminalSnapshot(lines: kept)
    }
}

extension TerminalLine {
    /// Trims from the front, dropping runs that vanish entirely — the style of a run made of
    /// nothing but padding has nothing left to apply to.
    func trimmingLeadingWhitespace() -> TerminalLine {
        var runs = self.runs
        while let first = runs.first {
            let trimmed = String(first.text.drop(while: { $0 == " " || $0 == "\t" }))
            if trimmed.isEmpty {
                runs.removeFirst()
            } else {
                runs[0].text = trimmed
                break
            }
        }
        return TerminalLine(runs: runs)
    }

    func trimmingTrailingWhitespace() -> TerminalLine {
        var runs = self.runs
        while let last = runs.last {
            var text = last.text
            while let character = text.last, character == " " || character == "\t" {
                text.removeLast()
            }
            if text.isEmpty {
                runs.removeLast()
            } else {
                runs[runs.count - 1].text = text
                break
            }
        }
        return TerminalLine(runs: runs)
    }
}
