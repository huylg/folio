import AppKit

/// TextKit supplies Unicode word/grapheme movement. Its geometry data source projects each
/// component's native line and caret information into the stack's coordinate system.
final class DocumentSelectionDataSource: NSObject, NSTextSelectionDataSource {
    weak var stack: DocumentStackView?
    init(stack: DocumentStackView) { self.stack = stack }
    private var index: DocumentTextIndex { stack?.selectionController.index ?? DocumentTextIndex(components: []) }
    var documentRange: NSTextRange {
        NSTextRange(location: DocumentTextLocation(0), end: DocumentTextLocation(index.length))!
    }
    func offset(from: any NSTextLocation, to: any NSTextLocation) -> Int {
        guard let a = from as? DocumentTextLocation, let b = to as? DocumentTextLocation else { return NSNotFound }
        return b.offset - a.offset
    }
    func location(_ location: any NSTextLocation, offsetBy offset: Int) -> (any NSTextLocation)? {
        guard let location = location as? DocumentTextLocation else { return nil }
        let next = location.offset + offset
        return (0...index.length).contains(next) ? DocumentTextLocation(next) : nil
    }
    func baseWritingDirection(at location: any NSTextLocation) -> NSTextSelectionNavigation.WritingDirection {
        guard let value = location as? DocumentTextLocation,
              let surface = stack?.surface(containing: value.offset), let manager = surface.manager,
              let content = manager.textContentManager,
              let local = content.location(content.documentRange.location,
                offsetBy: max(0, value.offset - surface.range.location + surface.localStart)) else { return .leftToRight }
        return manager.baseWritingDirection(at: local)
    }
    func textRange(for granularity: NSTextSelection.Granularity,
                   enclosing location: any NSTextLocation) -> NSTextRange? {
        guard let value = location as? DocumentTextLocation, index.length > 0 else { return nil }
        let offset = min(index.length - 1, max(0, value.offset))
        let range: NSRange
        switch granularity {
        case .character: range = index.string.rangeOfComposedCharacterSequence(at: offset)
        case .paragraph: range = index.string.paragraphRange(for: NSRange(location: offset, length: 0))
        case .line: range = stack?.surface(containing: offset)?.lineRange(at: offset)
            ?? index.string.lineRange(for: NSRange(location: offset, length: 0))
        case .sentence: range = index.string.paragraphRange(for: NSRange(location: offset, length: 0))
        case .word:
            var found = NSRange(location: offset, length: 1)
            index.string.enumerateSubstrings(in: index.string.paragraphRange(for: NSRange(location: offset, length: 0)),
                options: [.byWords, .substringNotRequired]) { _, range, _, stop in
                if NSLocationInRange(offset, range) { found = range; stop.pointee = true }
                else if range.location > offset { stop.pointee = true }
            }
            range = found
        @unknown default: range = NSRange(location: offset, length: 0)
        }
        return NSTextRange(location: DocumentTextLocation(range.location),
                           end: DocumentTextLocation(NSMaxRange(range)))
    }
    func enumerateSubstrings(from location: any NSTextLocation, options: NSString.EnumerationOptions,
        using block: (String?, NSTextRange, NSTextRange?, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let location = location as? DocumentTextLocation else { return }
        let value = min(index.length, max(0, location.offset))
        let reverse = options.contains(.reverse)
        if options.contains(.byLines), let stack {
            var cursor = value
            var stop = ObjCBool(false)
            while reverse ? cursor > 0 : cursor < index.length {
                guard let surface = stack.surface(containing: reverse ? cursor - 1 : cursor),
                      let line = surface.lineRange(at: reverse ? cursor - 1 : cursor) else { break }
                let range = NSTextRange(location: DocumentTextLocation(line.location),
                                        end: DocumentTextLocation(NSMaxRange(line)))!
                block(index.string.substring(with: index.clamped(line)), range, range, &stop)
                let next = reverse ? line.location : NSMaxRange(line)
                if stop.boolValue || next == cursor { break }
                cursor = next
            }
            return
        }
        let range = reverse ? NSRange(location: 0, length: value)
            : NSRange(location: value, length: index.length - value)
        withoutActuallyEscaping(block) { callback in
          index.string.enumerateSubstrings(in: range, options: options) { string, range, enclosing, stop in
            callback(string, NSTextRange(location: DocumentTextLocation(range.location),
                                       end: DocumentTextLocation(NSMaxRange(range)))!,
                  NSTextRange(location: DocumentTextLocation(enclosing.location),
                              end: DocumentTextLocation(NSMaxRange(enclosing))), stop)
        }
        }
    }
    func enumerateCaretOffsetsInLineFragment(at location: any NSTextLocation,
        using block: (CGFloat, any NSTextLocation, Bool, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let value = location as? DocumentTextLocation, let stack,
              let surface = stack.surface(containing: value.offset), let view = surface.view else { return }
        guard let manager = surface.manager, let content = manager.textContentManager,
              let local = content.location(content.documentRange.location,
                offsetBy: max(0, value.offset - surface.range.location + surface.localStart)) else {
            var stop = ObjCBool(false)
            block(view.convert(surface.frame.origin, to: stack).x,
                  DocumentTextLocation(surface.range.location), true, &stop)
            if !stop.boolValue {
                block(view.convert(NSPoint(x: surface.frame.maxX, y: surface.frame.minY), to: stack).x,
                      DocumentTextLocation(NSMaxRange(surface.range)), false, &stop)
            }
            return
        }
        manager.enumerateCaretOffsetsInLineFragment(at: local) { x, location, leading, stop in
            let offset = content.offset(from: content.documentRange.location, to: location)
            let global = surface.range.location + offset - surface.localStart
            let x = view.convert(NSPoint(x: x + surface.frame.minX, y: 0), to: stack).x
            block(x, DocumentTextLocation(global), leading, stop)
        }
    }
    func lineFragmentRange(for point: CGPoint, inContainerAt location: any NSTextLocation) -> NSTextRange? {
        guard let stack, let surface = stack.surface(at: point) else { return nil }
        let offset = stack.selectionOffset(at: point)
        let line = surface.lineRange(at: offset) ?? surface.range
        return NSTextRange(location: DocumentTextLocation(line.location),
                           end: DocumentTextLocation(NSMaxRange(line)))
    }
}

extension TextSelectionSurface {
    func lines() -> [(range: NSRange, frame: NSRect)] {
        guard let manager, let content = manager.textContentManager else { return [(range, frame)] }
        var lines: [(NSRange, NSRect)] = []
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let local = line.characterRange
                let global = NSRange(location: self.range.location + start + local.location - self.localStart,
                                     length: local.length)
                let clipped = NSIntersectionRange(self.range, global)
                if clipped.length > 0 {
                    lines.append((clipped, line.typographicBounds.offsetBy(
                        dx: self.frame.minX + fragment.layoutFragmentFrame.minX,
                        dy: self.frame.minY + fragment.layoutFragmentFrame.minY)))
                }
            }
            return true
        }
        return lines
    }
    func lineRange(at offset: Int) -> NSRange? {
        guard let manager, let content = manager.textContentManager else { return range }
        let localOffset = min(max(0, offset - range.location + localStart), attributed?.length ?? 0)
        guard let location = content.location(content.documentRange.location, offsetBy: localOffset) else { return nil }
        manager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = manager.textLayoutFragment(for: location) else { return nil }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let line = fragment.textLineFragments.first {
            NSMaxRange($0.characterRange) > localOffset - start
        } ?? fragment.textLineFragments.last
        guard let line else { return nil }
        return NSIntersectionRange(range, NSRange(
            location: range.location + start + line.characterRange.location - localStart,
            length: line.characterRange.length))
    }
}

extension DocumentStackView: NSUserInterfaceValidations {
    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return selectionController.selectedRange.length > 0
        case #selector(selectAll(_:)): return selectionController.index.length > 0
        case #selector(performTextFinderAction(_:)):
            return NSTextFinder.Action(rawValue: item.tag).map { validateFindAction?($0) ?? false } ?? false
        default: return true
        }
    }

    private func moveSelection(_ direction: NSTextSelectionNavigation.Direction,
        _ destination: NSTextSelectionNavigation.Destination = .character, extend: Bool = false) {
        let controller = selectionController
        if direction == .up || direction == .down, destination == .character,
           let next = verticalSelectionDestination(from: controller.focus, down: direction == .down) {
            controller.set(anchor: extend ? controller.anchor : next, focus: next)
            revealSelection(NSRange(location: next, length: 0))
            return
        }
        if destination == .line, let surface = surface(containing: controller.focus),
           let line = surface.lineRange(at: controller.focus) {
            let offset = direction == .backward ? line.location : NSMaxRange(line)
            controller.set(anchor: extend ? controller.anchor : offset, focus: offset)
            revealSelection(NSRange(location: offset, length: 0))
            return
        }
        controller.preferredColumnX = nil
        let current = extend ? NSRange(location: controller.focus, length: 0) : controller.selectedRange
        let selection = NSTextSelection(range: NSTextRange(location: DocumentTextLocation(current.location),
            end: DocumentTextLocation(NSMaxRange(current)))!, affinity: .downstream, granularity: .character)
        guard let next = selectionNavigation.destinationSelection(for: selection, direction: direction,
            destination: destination, extending: false, confined: false),
              let range = DocumentSelectionController.range(next) else { return }
        let offset = range.location
        controller.set(anchor: extend ? controller.anchor : offset, focus: offset)
        revealSelection(NSRange(location: offset, length: 0))
    }

    private func verticalSelectionDestination(from offset: Int, down: Bool) -> Int? {
        guard let surface = surface(containing: offset) else { return nil }
        let lines = surface.lines()
        guard let lineIndex = lines.firstIndex(where: { offset < NSMaxRange($0.range) }) ?? lines.indices.last else { return nil }
        let caret = surface.rects(for: NSRange(location: offset, length: 0)).first
        let x = selectionController.preferredColumnX
            ?? ((caret?.minX ?? lines[lineIndex].frame.minX) - surface.frame.minX)
        selectionController.preferredColumnX = x
        let adjacent = lineIndex + (down ? 1 : -1)
        if lines.indices.contains(adjacent) {
            return surface.offset(at: NSPoint(x: surface.frame.minX + x, y: lines[adjacent].frame.midY))
        }
        let index = selectionController.index
        var position = down ? NSMaxRange(surface.range) : surface.range.location - 1
        while position >= 0 && position < index.length {
            guard let segment = index.segment(at: position) else { break }
            if segment.isSeparator {
                position = down ? NSMaxRange(segment.range) : segment.range.location - 1
                continue
            }
            // Split list separators live in their body segment. Move past them when a
            // fragment has omitted a trailing newline from its visual range.
            if let next = self.surface(containing: position), next !== surface,
               let line = down ? next.lines().first : next.lines().last {
                return next.offset(at: NSPoint(x: next.frame.minX + x, y: line.frame.midY))
            }
            position += down ? 1 : -1
        }
        return down ? index.length : 0
    }
    public override func moveLeft(_ sender: Any?) { moveSelection(.left) }
    public override func moveRight(_ sender: Any?) { moveSelection(.right) }
    public override func moveUp(_ sender: Any?) { moveSelection(.up) }
    public override func moveDown(_ sender: Any?) { moveSelection(.down) }
    public override func moveLeftAndModifySelection(_ sender: Any?) { moveSelection(.left, extend: true) }
    public override func moveRightAndModifySelection(_ sender: Any?) { moveSelection(.right, extend: true) }
    public override func moveUpAndModifySelection(_ sender: Any?) { moveSelection(.up, extend: true) }
    public override func moveDownAndModifySelection(_ sender: Any?) { moveSelection(.down, extend: true) }
    public override func moveWordLeft(_ sender: Any?) { moveSelection(.left, .word) }
    public override func moveWordRight(_ sender: Any?) { moveSelection(.right, .word) }
    public override func moveWordLeftAndModifySelection(_ sender: Any?) { moveSelection(.left, .word, extend: true) }
    public override func moveWordRightAndModifySelection(_ sender: Any?) { moveSelection(.right, .word, extend: true) }
    public override func moveToBeginningOfLine(_ sender: Any?) { moveSelection(.backward, .line) }
    public override func moveToEndOfLine(_ sender: Any?) { moveSelection(.forward, .line) }
    public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { moveSelection(.backward, .line, extend: true) }
    public override func moveToEndOfLineAndModifySelection(_ sender: Any?) { moveSelection(.forward, .line, extend: true) }
    public override func moveToBeginningOfDocument(_ sender: Any?) { moveSelection(.backward, .document) }
    public override func moveToEndOfDocument(_ sender: Any?) { moveSelection(.forward, .document) }
    public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { moveSelection(.backward, .document, extend: true) }
    public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { moveSelection(.forward, .document, extend: true) }
    public override func moveParagraphBackwardAndModifySelection(_ sender: Any?) { moveSelection(.backward, .paragraph, extend: true) }
    public override func moveParagraphForwardAndModifySelection(_ sender: Any?) { moveSelection(.forward, .paragraph, extend: true) }

    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilitySelectedTextRanges() -> [NSValue]? {
        [NSValue(range: selectionController.selectedRange)]
    }
    public override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        if let range = ranges?.first?.rangeValue { selectionController.setRange(range) }
    }
    public override func accessibilityValue() -> Any? { selectionController.index.string }
    public override func accessibilitySelectedText() -> String? { selectionController.selectedText }
    public override func accessibilitySelectedTextRange() -> NSRange { selectionController.selectedRange }
    public override func setAccessibilitySelectedTextRange(_ range: NSRange) { selectionController.setRange(range) }
    public override func accessibilityNumberOfCharacters() -> Int { selectionController.index.length }
    public override func accessibilityString(for range: NSRange) -> String? {
        selectionController.index.string.substring(with: selectionController.index.clamped(range))
    }
    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window else { return .zero }
        _ = surface(containing: range.location)
        let rect = selectionRects(range).reduce(NSRect.null) { $0.union($1) }
        return rect.isNull ? .zero : window.convertToScreen(convert(rect, to: nil))
    }
}
