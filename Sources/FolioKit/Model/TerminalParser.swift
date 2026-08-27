import Foundation

/// Turns a stream of pty bytes into a `TerminalSnapshot`.
///
/// Not a terminal emulator, and deliberately so. It keeps the escapes that carry *style*,
/// applies the ones that move *within a line*, and drops everything else on the floor:
///
/// - **SGR** (`CSI … m`) — the whole point. 16-color, 256-color, and 24-bit foreground and
///   background, plus bold, faint, italic, underline, inverse, and strikethrough with their
///   resets.
/// - **`\r`** rewrites its line, which is how a progress bar's hundred repaints collapse into
///   its final state instead of a hundred rows.
/// - **`\n`** moves down a line and, as on a real terminal, does *not* return to column zero —
///   the tty's own line discipline (ONLCR) is what turns a program's bare `\n` into `\r\n`
///   before the pty master ever sees it.
/// - **`CSI … K`** erases within the line.
/// - **OSC** (window titles and friends) and **every other CSI** are swallowed silently.
///
/// What it therefore cannot do is multi-line in-place repainting — `\e[2A` then a rewrite, the
/// way docker, cargo, and npm draw their progress. Those stack as repeated frames instead of
/// updating in place. That was measured against a real embedded terminal on five realistic
/// streams: four rendered identically, and this was the only difference. It is not worth a
/// binary dependency to a reading app.
///
/// The parser is incremental and holds all of its state across calls: `\e[3` may arrive in one
/// read and `1mred` in the next, and a UTF-8 sequence may be split the same way. Only whole
/// characters ever reach the grid.
final class TerminalParser {

    /// One character and the style it was printed with. A grid of these is what `\r` overwrites
    /// and `K` erases — the operations only make sense per cell, not on a string.
    private struct Cell {
        var character: Character
        var style: TerminalCellStyle
    }

    private var lines: [[Cell]] = [[]]
    private var row = 0
    private var column = 0
    private var style = TerminalCellStyle()

    private enum State {
        case ground
        /// Saw ESC, waiting to learn what kind of sequence this is.
        case escape
        /// Inside a non-CSI escape that took an intermediate byte — `ESC ( B` and the other
        /// charset selections — waiting for the final byte that ends it.
        case escapeIntermediate
        /// Inside `CSI …`, collecting parameter and intermediate bytes.
        case csi
        /// Inside a string sequence (OSC, DCS, PM, APC), waiting for BEL or ST.
        case string
        /// Saw ESC inside a string sequence — the `\` that follows makes it an ST.
        case stringEscape
    }

    private var state: State = .ground
    /// The parameter and intermediate bytes of the CSI being collected.
    private var csiBytes: [UInt8] = []
    /// Printable bytes not yet decoded — held here so a UTF-8 sequence split across two reads
    /// is assembled rather than turned into two replacement characters.
    private var pendingText: [UInt8] = []

    // MARK: Feeding

    func feed(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes { consume(byte) }
        // Whatever is left is either complete text (emit it, so the console shows the line the
        // command just wrote) or a half-arrived UTF-8 sequence (hold it for the next read).
        flushText(holdingIncompleteSequence: true)
    }

    func feed(_ bytes: [UInt8]) { feed(bytes[...]) }

    func feed(_ data: Data) { feed([UInt8](data)[...]) }

    /// The convenience the tests are written against — a fixture is easier to read as a string
    /// than as bytes.
    func feed(_ text: String) { feed(ArraySlice(Array(text.utf8))) }

    private func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            switch byte {
            case 0x5B: // [
                state = .csi
                csiBytes = []
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // OSC, DCS, SOS, PM, APC
                state = .string
            case 0x20...0x2F:
                // An intermediate byte: this escape is longer than two bytes. `ESC ( B` —
                // "US-ASCII in G0" — is the common one, and swallowing only its first two
                // bytes would print the `B`.
                state = .escapeIntermediate
            default:
                // A two-byte escape. Nothing here moves within a line or carries style.
                state = .ground
            }
        case .escapeIntermediate:
            // More intermediates keep it going; anything else is the final byte.
            if !(0x20...0x2F).contains(byte) { state = .ground }
        case .csi:
            // Parameter bytes (0x30–0x3F) and intermediates (0x20–0x2F) accumulate; the first
            // byte in 0x40–0x7E ends the sequence and says what it was.
            if (0x30...0x3F).contains(byte) || (0x20...0x2F).contains(byte) {
                csiBytes.append(byte)
            } else if (0x40...0x7E).contains(byte) {
                dispatchCSI(final: byte)
                state = .ground
            } else {
                // A control byte interrupting a sequence is executed, not swallowed — the
                // sequence is simply abandoned, which is what a real terminal does.
                state = .ground
                ground(byte)
            }
        case .string:
            switch byte {
            case 0x07: state = .ground              // BEL terminates an OSC
            case 0x1B: state = .stringEscape
            default: break
            }
        case .stringEscape:
            switch byte {
            case 0x5C: state = .ground              // ESC \ — the two-byte ST
            case 0x1B: break                        // another ESC; keep waiting
            default: state = .string
            }
        }
    }

    private func ground(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            flushText(holdingIncompleteSequence: false)
            state = .escape
        case 0x0A:
            flushText(holdingIncompleteSequence: false)
            lineFeed()
        case 0x0D:
            flushText(holdingIncompleteSequence: false)
            column = 0
        case 0x08:
            flushText(holdingIncompleteSequence: false)
            column = max(0, column - 1)
        case 0x09:
            // A tab is kept as one cell rather than expanded to a tab stop: the console's text
            // view lays tabs out itself, and expanding here would disagree with it.
            pendingText.append(byte)
        case 0x00...0x1F, 0x7F:
            // Every other C0 control, and DEL. A BEL that reached here is not a beep worth
            // making, and none of them may land in the text as a literal.
            break
        default:
            pendingText.append(byte)
        }
    }

    // MARK: Text

    /// Decodes the buffered printable bytes and writes them into the grid.
    ///
    /// With `holdingIncompleteSequence`, a trailing UTF-8 sequence that has not fully arrived is
    /// kept back for the next read. Without it — the flush a control byte forces — everything
    /// is decoded, because a control byte cannot appear inside a UTF-8 sequence, so whatever is
    /// buffered is all there will ever be.
    private func flushText(holdingIncompleteSequence: Bool) {
        guard !pendingText.isEmpty else { return }
        var complete = pendingText.count
        if holdingIncompleteSequence {
            // Walk back to the lead byte of the last sequence and ask how long it claims to be.
            var start = pendingText.count - 1
            while start > 0, pendingText[start] & 0xC0 == 0x80 { start -= 1 }
            let lead = pendingText[start]
            let length: Int
            switch lead {
            case 0x00...0x7F: length = 1
            case 0xC0...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF7: length = 4
            default: length = 1 // a stray continuation byte: let the decoder answer for it
            }
            if start + length > pendingText.count { complete = start }
        }
        guard complete > 0 else { return }
        let text = String(decoding: pendingText[0..<complete], as: UTF8.self)
        pendingText.removeFirst(complete)
        for character in text { put(character) }
    }

    private func put(_ character: Character) {
        let cell = Cell(character: character, style: style)
        // A cursor parked past the end of its line — `\e[10C` and the like are ignored, but a
        // line can still be short of it after an erase — pads with blanks rather than dropping
        // the character somewhere it did not go.
        while lines[row].count < column {
            lines[row].append(Cell(character: " ", style: .plain))
        }
        if column < lines[row].count {
            lines[row][column] = cell
        } else {
            lines[row].append(cell)
        }
        column += 1
    }

    private func lineFeed() {
        row += 1
        while lines.count <= row { lines.append([]) }
    }

    // MARK: Sequences

    private func dispatchCSI(final: UInt8) {
        // Private sequences (`CSI ? … h`, cursor hiding and friends) carry no style and move
        // nothing within a line.
        guard !csiBytes.contains(where: { (0x3C...0x3F).contains($0) }) else { return }
        switch final {
        case 0x6D: applySGR(parameters())     // m
        case 0x4B: eraseInLine(parameters())  // K
        default: break                        // everything else, silently
        }
    }

    /// The CSI's parameters, as groups of colon-joined sub-parameters. Almost every sequence
    /// has one integer per group; only the extended-color forms use colons.
    private func parameters() -> [[Int]] {
        let text = String(decoding: csiBytes.filter { (0x30...0x3B).contains($0) }, as: UTF8.self)
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: ";").map { group in
            group.components(separatedBy: ":").map { Int($0) ?? 0 }
        }
    }

    /// `CSI K` erases within the line. Truncation rather than blank-filling: the console has no
    /// fixed width to fill out to, and a run of trailing spaces is not something a reader wants
    /// selected and copied.
    private func eraseInLine(_ parameters: [[Int]]) {
        switch parameters.first?.first ?? 0 {
        case 0:
            if column < lines[row].count { lines[row].removeSubrange(column...) }
        case 1:
            let end = min(column + 1, lines[row].count)
            for index in 0..<end {
                lines[row][index] = Cell(character: " ", style: .plain)
            }
        case 2:
            lines[row].removeAll()
        default:
            break
        }
    }

    private func applySGR(_ parameters: [[Int]]) {
        // A bare `CSI m` is `CSI 0 m`.
        guard !parameters.isEmpty else {
            style = .plain
            return
        }
        var index = 0
        while index < parameters.count {
            let group = parameters[index]
            let code = group.first ?? 0
            switch code {
            case 0: style = .plain
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            // 21 is a *doubly* underlined run, which this renderer draws as a plain one —
            // still underlined, which is the part that carries meaning.
            case 21: style.underline = true
            case 24: style.underline = false
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .palette(UInt8(code - 30))
            case 39: style.foreground = .default
            case 40...47: style.background = .palette(UInt8(code - 40))
            case 49: style.background = .default
            case 90...97: style.foreground = .palette(UInt8(code - 90 + 8))
            case 100...107: style.background = .palette(UInt8(code - 100 + 8))
            case 38, 48, 58:
                let (color, consumed) = extendedColor(parameters, at: index)
                if let color {
                    switch code {
                    case 38: style.foreground = color
                    case 48: style.background = color
                    default: style.underlineColor = color
                    }
                }
                index += consumed
            case 59: style.underlineColor = .default
            default: break
            }
            index += 1
        }
    }

    /// Reads a `38`/`48`/`58` extended color, in either spelling.
    ///
    /// The common form spreads over following semicolon groups (`38;5;n`, `38;2;r;g;b`); the
    /// ITU form packs them into one colon group (`38:5:n`, `38:2::r:g:b`, where the empty field
    /// is a color space nobody sets). Returns the color and how many *extra* groups it ate.
    private func extendedColor(_ parameters: [[Int]], at index: Int) -> (TerminalColor?, Int) {
        let group = parameters[index]
        if group.count > 1 {
            // Colon form: self-contained, so it never consumes a following group.
            switch group[1] {
            case 5 where group.count >= 3:
                return (.palette(clamped(group[2])), 0)
            case 2 where group.count >= 5:
                // With a color-space field present the channels sit one later.
                let base = group.count >= 6 ? 3 : 2
                return (.rgb(clamped(group[base]), clamped(group[base + 1]),
                             clamped(group[base + 2])), 0)
            default:
                return (nil, 0)
            }
        }
        func value(_ offset: Int) -> Int? {
            let position = index + offset
            guard position < parameters.count else { return nil }
            return parameters[position].first
        }
        switch value(1) {
        case 5:
            guard let index = value(2) else { return (nil, 1) }
            return (.palette(clamped(index)), 2)
        case 2:
            guard let red = value(2), let green = value(3), let blue = value(4) else {
                return (nil, parameters.count - index - 1)
            }
            return (.rgb(clamped(red), clamped(green), clamped(blue)), 4)
        default:
            return (nil, 1)
        }
    }

    private func clamped(_ value: Int) -> UInt8 { UInt8(min(255, max(0, value))) }

    // MARK: Output

    /// The grid as a snapshot, with adjacent same-style cells coalesced into runs — one run per
    /// stretch of text an attributed string needs a distinct set of attributes for.
    func snapshot() -> TerminalSnapshot {
        TerminalSnapshot(lines: lines.map { cells in
            var runs: [TerminalRun] = []
            for cell in cells {
                if var last = runs.last, last.style == cell.style {
                    last.text.append(cell.character)
                    runs[runs.count - 1] = last
                } else {
                    runs.append(TerminalRun(text: String(cell.character), style: cell.style))
                }
            }
            return TerminalLine(runs: runs)
        })
    }
}
