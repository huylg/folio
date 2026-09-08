import AppKit

/// Immutable reading-order text. These UTF-16 offsets are deliberately independent of the
/// builder's attachment/navigation offsets and of the views currently in the viewport.
struct DocumentTextIndex {
    enum Part: Hashable {
        case body
        case cell(row: Int, column: Int) // zero is the original header
        case key(String)
        case value(String)
        case tag(String, Int)
        case object
        case separator(Int)
    }

    struct ID: Hashable { let component: Int; let part: Part }
    struct Segment: Equatable {
        let id: ID
        let range: NSRange
        let replacement: String?
        var isSeparator: Bool { if case .separator = id.part { return true }; return false }
    }

    let string: NSString
    let segments: [Segment]
    let componentRanges: [NSRange]
    let identities: [NSRange]
    private let lookup: [ID: Int]
    var length: Int { string.length }
    var fullRange: NSRange { NSRange(location: 0, length: length) }

    init(components: [DocumentComponent]) {
        let text = NSMutableString(capacity: 0)
        var segments: [Segment] = []
        var ranges: [NSRange] = []
        var separator = 0
        func append(_ value: String, component: Int, part: Part, replacement: String? = nil) {
            let range = NSRange(location: text.length, length: (value as NSString).length)
            text.append(value)
            segments.append(Segment(id: ID(component: component, part: part), range: range,
                                    replacement: replacement))
        }
        func separate(_ value: String, component: Int) {
            append(value, component: component, part: .separator(separator))
            separator += 1
        }
        for (i, component) in components.enumerated() {
            if case .meta = component.kind {
                ranges.append(NSRange(location: text.length, length: 0))
                continue // generated reading statistics are interface chrome
            }
            if text.length > 0 { separate("\n\n", component: i - 1) }
            let start = text.length
            switch component.content {
            case .text(let attributed):
                // Block ranges exclude the builder's final terminator; internal paragraph
                // breaks inside lists and quotes belong to the displayed text.
                append(attributed.string, component: i, part: .body)
            case .code(_, let source, _, _):
                append(source, component: i, part: .body)
            case .widget(.table(let table)):
                for (row, cells) in ([table.header] + table.rows).enumerated() {
                    if row > 0 { separate("\n", component: i) }
                    for (column, cell) in cells.enumerated() {
                        if column > 0 { separate("\t", component: i) }
                        append(cell.text.string, component: i, part: .cell(row: row, column: column))
                    }
                }
            case .widget(.frontmatter(let metadata)):
                for (row, key) in metadata.orderedKeys.enumerated() {
                    guard let value = metadata.values[key] else { continue }
                    if row > 0 { separate("\n", component: i) }
                    append(key, component: i, part: .key(key))
                    separate(": ", component: i)
                    if Self.isTagKey(key), case .list(let tags) = value {
                        for (j, tag) in tags.enumerated() {
                            if j > 0 { separate(", ", component: i) }
                            append(tag, component: i, part: .tag(key, j))
                        }
                    } else { append(value.display, component: i, part: .value(key)) }
                }
            case .widget(.htmlBlock(let source)), .widget(.math(let source, _)):
                append(source, component: i, part: .body)
            case .widget(.diagram(let source, let graph)) where graph == nil:
                append(source, component: i, part: .body)
            case .widget(let payload):
                append("\u{fffc}", component: i, part: .object, replacement: payload.copyText)
            case .rule:
                append("\u{fffc}", component: i, part: .object, replacement: "---")
            }
            ranges.append(NSRange(location: start, length: text.length - start))
        }
        self.string = text.copy() as! NSString
        self.segments = segments
        self.componentRanges = ranges
        self.identities = components.map(\.range)
        self.lookup = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
    }

    static func isTagKey(_ key: String) -> Bool { ["tags", "tag", "keywords"].contains(key) }

    func segment(component: Int, part: Part) -> Segment? {
        lookup[ID(component: component, part: part)].map { segments[$0] }
    }

    func segment(at offset: Int) -> Segment? {
        guard !segments.isEmpty else { return nil }
        let position = min(max(0, offset), max(0, length - 1))
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(segments[mid].range) <= position { low = mid + 1 } else { high = mid }
        }
        return segments[min(low, segments.count - 1)]
    }

    func clamped(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let start = min(max(0, range.location), length)
        return NSRange(location: start, length: min(max(0, range.length), length - start))
    }

    func copyText(in proposed: NSRange) -> String {
        let range = clamped(proposed)
        let result = NSMutableString(string: string.substring(with: range))
        for segment in segments.reversed() where segment.replacement != nil {
            guard NSIntersectionRange(range, segment.range).length > 0 else { continue }
            result.replaceCharacters(in: NSRange(location: segment.range.location - range.location,
                                                 length: segment.range.length),
                                     with: segment.replacement!)
        }
        return result as String
    }

    func isSearchable(_ range: NSRange) -> Bool {
        range.length > 0 && !segments.contains {
            $0.replacement != nil && NSIntersectionRange($0.range, range).length > 0
        }
    }

    func equivalent(to other: Self) -> Bool {
        string == other.string && segments == other.segments && identities == other.identities
    }
}
