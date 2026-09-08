import AppKit

/// Shared TextKit 2 geometry for painted cells and labels. No text view, responder or field
/// editor is created. Layout, drawing, hit testing and highlights use the same container.
final class SelectionTextLayout {
    let storage = NSTextContentStorage()
    let manager = NSTextLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    let attributed: NSAttributedString
    private var measuredWidth: CGFloat = -1

    init(_ text: NSAttributedString) {
        attributed = text
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        storage.textStorage?.setAttributedString(text)
    }

    func layout(width: CGFloat) {
        let width = max(1, width)
        guard width != measuredWidth else { return }
        measuredWidth = width
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: manager.documentRange)
    }

    func draw(at origin: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location,
                                             options: [.ensuresLayout]) { fragment in
            fragment.draw(at: NSPoint(x: origin.x + fragment.layoutFragmentFrame.minX,
                                      y: origin.y + fragment.layoutFragmentFrame.minY), in: context)
            return true
        }
    }
}

protocol DocumentSelectionSurface: AnyObject {
    var range: NSRange { get }
    var view: NSView? { get }
    var frame: NSRect { get }
    func offset(at point: NSPoint) -> Int
    func rects(for range: NSRange) -> [NSRect]
}

/// One local text slice projected into the document. A list page can start inside a segment;
/// a table fragment can have several surfaces. Atomic surfaces have no layout manager.
final class TextSelectionSurface: DocumentSelectionSurface {
    weak var view: NSView?
    weak var stack: DocumentStackView?
    lazy var accessibilityElement = SelectionAccessibilityElement(surface: self)
    let part: DocumentTextIndex.Part
    var range = NSRange(location: 0, length: 0)
    var localStart = 0
    let manager: NSTextLayoutManager?
    let attributed: NSAttributedString?
    var frame: NSRect
    var isBound = false

    init(view: NSView, part: DocumentTextIndex.Part, frame: NSRect,
         manager: NSTextLayoutManager? = nil, attributed: NSAttributedString? = nil) {
        self.view = view; self.part = part; self.frame = frame
        self.manager = manager; self.attributed = attributed
    }

    func offset(at point: NSPoint) -> Int {
        guard let manager, let content = manager.textContentManager else {
            return range.location + (point.x > frame.midX ? range.length : 0)
        }
        let local = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let selected = manager.textSelectionNavigation.textSelections(
            interactingAt: local, inContainerAt: content.documentRange.location,
            anchors: [], modifiers: [], selecting: false,
            bounds: NSRect(origin: .zero, size: frame.size))
        guard let location = selected.first?.textRanges.first?.location else { return range.location }
        let offset = content.offset(from: content.documentRange.location, to: location)
        return range.location + min(range.length, max(0, offset - localStart))
    }

    func rects(for proposed: NSRange) -> [NSRect] {
        let intersection = NSIntersectionRange(range, proposed)
        guard intersection.length > 0 || (proposed.length == 0 &&
            proposed.location >= range.location && proposed.location <= NSMaxRange(range)) else { return [] }
        guard let manager else { return [frame.insetBy(dx: 0, dy: -2)] }
        let local = NSRange(location: max(0, intersection.location - range.location + localStart),
                            length: intersection.length)
        return manager.selectionRects(local).map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
    }

    func link(at point: NSPoint) -> String? {
        guard let attributed, attributed.length > 0 else { return nil }
        let index = offset(at: point) - range.location + localStart
        for candidate in [index, index - 1] where candidate >= 0 && candidate < attributed.length {
            var localRange = NSRange()
            guard let link = attributed.attribute(.link, at: candidate,
                                                   effectiveRange: &localRange) else { continue }
            let global = NSRange(location: range.location + localRange.location - localStart,
                                 length: localRange.length)
            guard rects(for: global).contains(where: { $0.contains(point) }) else { continue }
            return (link as? String) ?? (link as? URL)?.absoluteString
        }
        return nil
    }

    func paint(controller: DocumentSelectionController) {
        guard isBound else { return }
        for match in controller.matches(intersecting: range) {
            for rect in rects(for: match) { NSTextFinder.drawIncrementalMatchHighlight(in: rect) }
        }
        let color = controller.isActive ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        color.setFill()
        for rect in rects(for: controller.selectedRange) where controller.selectedRange.length > 0 {
            rect.fill()
        }
    }
}

final class SelectionAccessibilityElement: NSAccessibilityElement {
    weak var surface: TextSelectionSurface?
    init(surface: TextSelectionSurface) {
        self.surface = surface
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityParent(surface.view)
    }
    override func accessibilityValue() -> Any? { surface?.attributed?.string }
    override func accessibilityLabel() -> String? { surface?.attributed?.string }
    override func accessibilityFrame() -> NSRect {
        guard let surface, let view = surface.view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(surface.frame, to: nil))
    }
    override func accessibilitySelectedTextRange() -> NSRange {
        guard let surface, let stack = surface.stack else { return NSRange(location: 0, length: 0) }
        let range = NSIntersectionRange(surface.range, stack.selectionController.selectedRange)
        return NSRange(location: max(0, range.location - surface.range.location), length: range.length)
    }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let surface else { return }
        let start = min(surface.range.length, max(0, range.location))
        surface.stack?.selectionController.setRange(NSRange(location: surface.range.location + start,
            length: min(range.length, surface.range.length - start)))
    }
    override func accessibilitySelectedText() -> String? {
        guard let surface, let stack = surface.stack else { return nil }
        return stack.selectionController.index.copyText(in:
            NSIntersectionRange(surface.range, stack.selectionController.selectedRange))
    }
}

extension NSTextLayoutManager {
    func selectionRects(_ range: NSRange) -> [NSRect] {
        guard let content = textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        ensureLayout(for: textRange)
        var result: [NSRect] = []
        enumerateTextSegments(in: textRange, type: .selection, options: []) { _, frame, _, _ in
            result.append(frame); return true
        }
        return result
    }
}

/// Widgets provide surfaces only for their own document content, never their buttons or
/// embedded consoles. The stack binds these to its logical index after placement.
protocol DocumentSurfaceProvider: AnyObject {
    func documentSurfaces() -> [TextSelectionSurface]
}

protocol SelectionPaintOwner: AnyObject {
    var selectionStack: DocumentStackView? { get set }
}

final class DocumentSelectionOverlay: NSView {
    weak var stack: DocumentStackView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let stack else { return }
        let selection = stack.selectionController
        for surface in stack.selectionSurfaces() where surface.manager == nil {
            guard let view = surface.view,
                  NSIntersectionRange(surface.range, selection.selectedRange).length > 0 else { continue }
            let color = selection.isActive ? NSColor.selectedTextBackgroundColor
                : NSColor.unemphasizedSelectedTextBackgroundColor
            color.withAlphaComponent(0.4).setFill()
            view.convert(surface.frame, to: self).fill()
        }
        if selection.isActive, selection.selectedRange.length == 0 {
            NSColor.textColor.setFill()
            for rect in stack.selectionRects(selection.selectedRange).prefix(1) {
                NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
            }
        }
    }
}
