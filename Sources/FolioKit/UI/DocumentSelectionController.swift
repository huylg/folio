import AppKit

/// Selection survives view recycling because only the document owns the endpoints.
final class DocumentSelectionController {
    private(set) var index = DocumentTextIndex(components: [])
    private(set) var anchor = 0
    private(set) var focus = 0
    var affinity: NSSelectionAffinity = .downstream
    var preferredColumnX: CGFloat?
    private(set) var granularity: NSTextSelection.Granularity = .character
    var isActive = false { didSet { if oldValue != isActive { onChange?() } } }
    var isDragging = false
    var onChange: (() -> Void)?
    var onWillReplace: (() -> Void)?
    var onDidReplace: ((DocumentTextIndex) -> Void)?
    private(set) var matchRanges: [NSRange] = []
    private var originalRange = NSRange(location: 0, length: 0)
    private var identity: URL?

    var selectedRange: NSRange {
        NSRange(location: min(anchor, focus), length: abs(focus - anchor))
    }
    var selectedText: String { index.copyText(in: selectedRange) }

    func replace(_ next: DocumentTextIndex, identity: URL?) {
        isDragging = false
        guard self.identity != identity || !index.equivalent(to: next) else { return }
        onWillReplace?()
        self.identity = identity
        index = next
        onDidReplace?(next)
        anchor = 0; focus = 0; matchRanges = []
        onChange?()
    }

    func setRange(_ range: NSRange) {
        preferredColumnX = nil
        let range = index.clamped(range)
        set(anchor: range.location, focus: NSMaxRange(range))
    }

    func set(anchor: Int, focus: Int) {
        let a = min(index.length, max(0, anchor)), f = min(index.length, max(0, focus))
        guard a != self.anchor || f != self.focus else { return }
        self.anchor = a; self.focus = f
        onChange?()
    }

    func begin(at offset: Int, extending: Bool, clicks: Int, navigation: NSTextSelectionNavigation) {
        preferredColumnX = nil
        granularity = clicks >= 3 ? .paragraph : clicks == 2 ? .word : .character
        let point = min(max(0, offset), index.length)
        let expanded = navigation.textSelection(for: granularity,
            enclosing: selection(NSRange(location: point, length: 0)))
        let range = granularity == .character ? NSRange(location: point, length: 0)
            : Self.range(expanded) ?? NSRange(location: point, length: 0)
        originalRange = extending ? NSRange(location: anchor, length: 0) : range
        if extending { set(anchor: anchor, focus: point) } else { setRange(range) }
    }

    func extend(to offset: Int, navigation: NSTextSelectionNavigation) {
        let point = min(max(0, offset), index.length)
        let expanded = navigation.textSelection(for: granularity,
            enclosing: selection(NSRange(location: point, length: 0)))
        let range = granularity == .character ? NSRange(location: point, length: 0)
            : Self.range(expanded) ?? NSRange(location: point, length: 0)
        if point < originalRange.location {
            set(anchor: NSMaxRange(originalRange), focus: range.location)
        } else { set(anchor: originalRange.location, focus: NSMaxRange(range)) }
    }

    func selectAll() { setRange(index.fullRange) }
    func selectObject(_ range: NSRange) {
        granularity = .character
        originalRange = range
        setRange(range)
    }
    func clear() { set(anchor: focus, focus: focus) }

    func setMatches(_ ranges: [NSRange]) {
        matchRanges = ranges.sorted { $0.location < $1.location }
        onChange?()
    }

    func matches(intersecting range: NSRange) -> ArraySlice<NSRange> {
        var low = 0, high = matchRanges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(matchRanges[mid]) <= range.location { low = mid + 1 } else { high = mid }
        }
        let first = low
        while low < matchRanges.count && matchRanges[low].location < NSMaxRange(range) { low += 1 }
        return matchRanges[first..<low]
    }

    func selection(_ range: NSRange) -> NSTextSelection {
        NSTextSelection(range: NSTextRange(location: DocumentTextLocation(range.location),
                                           end: DocumentTextLocation(NSMaxRange(range)))!,
                        affinity: affinity == .upstream ? .upstream : .downstream,
                        granularity: granularity)
    }

    static func range(_ selection: NSTextSelection) -> NSRange? {
        guard let range = selection.textRanges.first,
              let start = range.location as? DocumentTextLocation,
              let end = range.endLocation as? DocumentTextLocation else { return nil }
        return NSRange(location: start.offset, length: max(0, end.offset - start.offset))
    }
}

final class DocumentTextLocation: NSObject, NSTextLocation {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
    override var hash: Int { offset.hashValue }
    override func isEqual(_ object: Any?) -> Bool { (object as? DocumentTextLocation)?.offset == offset }
    func compare(_ location: any NSTextLocation) -> ComparisonResult {
        guard let other = location as? DocumentTextLocation else { return .orderedAscending }
        return offset < other.offset ? .orderedAscending : offset > other.offset ? .orderedDescending : .orderedSame
    }
}
