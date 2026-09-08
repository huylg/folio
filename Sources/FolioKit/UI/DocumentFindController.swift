import AppKit

/// Native Find searches an immutable snapshot. Only geometry callbacks touch live views.
final class DocumentFindController: NSObject, NSTextFinderClient {
    let finder = NSTextFinder()
    private weak var stack: DocumentStackView?
    private weak var scrollView: NSScrollView?
    private var observation: NSKeyValueObservation?
    private var keyMonitor: Any?
    private var snapshot: String = ""

    init(stack: DocumentStackView, scrollView: NSScrollView) {
        self.stack = stack; self.scrollView = scrollView
        super.init()
        snapshot = stack.selectionController.index.string as String
        finder.client = self
        finder.findBarContainer = scrollView
        scrollView.findBarPosition = .aboveContent
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
        observation = finder.observe(\.incrementalMatchRanges, options: [.new]) { [weak self] finder, _ in
            self?.stack?.selectionController.setMatches(finder.incrementalMatchRanges.map(\.rangeValue))
        }
        stack.selectionController.onWillReplace = { [weak self] in
            self?.finder.noteClientStringWillChange()
            self?.finder.cancelFindIndicator()
        }
        stack.selectionController.onDidReplace = { [weak self] index in self?.snapshot = index.string as String }
        stack.onFindAction = { [weak self] sender in self?.perform(sender) }
        stack.validateFindAction = { [weak self] action in self?.validate(action) ?? false }
        stack.onSelectionGeometryChange = { [weak self] in self?.finder.cancelFindIndicator() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let scrollView = self.scrollView, event.window === scrollView.window,
                  event.keyCode == 53, scrollView.isFindBarVisible else { return event }
            self.perform(NSMenuItem.findAction(.hideFindInterface))
            self.stack?.selectionController.setMatches([])
            scrollView.window?.makeFirstResponder(self.stack)
            return nil
        }
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    var string: String { snapshot }
    var isSelectable: Bool { true }
    var isEditable: Bool { false }
    var allowsMultipleSelection: Bool { false }
    var firstSelectedRange: NSRange { stack?.selectionController.selectedRange ?? NSRange(location: 0, length: 0) }
    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            if let range = newValue.first?.rangeValue { stack?.selectionController.setRange(range) }
        }
    }
    var visibleCharacterRanges: [NSValue] {
        guard let stack else { return [] }
        return stack.selectionSurfaces().filter { surface in
            guard let view = surface.view else { return false }
            return view.convert(surface.frame, to: stack).intersects(stack.visibleRect)
        }.map { NSValue(range: $0.range) }
    }
    func contentView(at index: Int, effectiveCharacterRange range: NSRangePointer) -> NSView {
        range.pointee = stack?.selectionController.index.fullRange ?? NSRange(location: 0, length: 0)
        return stack ?? NSView()
    }
    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        stack?.selectionRects(range).map { NSValue(rect: $0) }
    }
    func scrollRangeToVisible(_ range: NSRange) {
        // During incremental search AppKit navigates by scrolling, postponing its selectedRanges
        // setter until the bar closes. The document's Copy and accessible selection must follow
        // the active match immediately.
        stack?.selectionController.setRange(range)
        stack?.revealSelection(range)
    }
    func validate(_ action: NSTextFinder.Action) -> Bool {
        guard let stack, stack.selectionController.index.length > 0 else { return false }
        switch action {
        case .showFindInterface, .hideFindInterface, .nextMatch, .previousMatch:
            return finder.validateAction(action)
        case .setSearchString:
            return stack.selectionController.index.isSearchable(firstSelectedRange)
                && finder.validateAction(action)
        default: return false
        }
    }
    func perform(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        guard let action = NSTextFinder.Action(rawValue: tag), validate(action) else { return }
        finder.performAction(action)
    }
}

/// Keep AppKit's live Find controls and final viewport geometry, animating only their
/// presentation. Handling visibility here also covers the native bar's Done button.
final class DocumentFindScrollView: NSScrollView {
    static let findBarAnimationDuration: TimeInterval = 0.2
    var withFindBarLayout: ((() -> Void) -> Void)?
    private(set) var departingFindBar: NSView?
    private static let animationKey = "folio.findBarTransition"

    override var isFindBarVisible: Bool {
        get { super.isFindBarVisible }
        set {
            guard newValue != super.isFindBarVisible else { return }
            departingFindBar?.removeFromSuperview()
            departingFindBar = nil
            let animated = window != nil && !Ink.reduceMotion
            let departing = animated && !newValue ? snapshotFindBar() : nil
            findBarView?.layer?.removeAnimation(forKey: Self.animationKey)
            let operation = { super.isFindBarVisible = newValue }
            if let withFindBarLayout { withFindBarLayout(operation) } else { operation() }
            guard animated else { return }
            if newValue, let bar = findBarView {
                bar.wantsLayer = true
                animate(bar, appearing: true)
            } else if let departing {
                departingFindBar = departing
                addSubview(departing, positioned: .above, relativeTo: nil)
                animate(departing, appearing: false)
            }
        }
    }

    private func snapshotFindBar() -> NSView? {
        guard let bar = findBarView, bar.superview != nil,
              let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return nil }
        bar.cacheDisplay(in: bar.bounds, to: bitmap)
        let image = NSImage(size: bar.bounds.size)
        image.addRepresentation(bitmap)
        let snapshot = FindBarSnapshot(frame: convert(bar.bounds, from: bar))
        snapshot.image = image
        snapshot.imageScaling = .scaleAxesIndependently
        snapshot.wantsLayer = true
        snapshot.setAccessibilityElement(false)
        return snapshot
    }

    private func animate(_ view: NSView, appearing: Bool) {
        guard let layer = view.layer else { return }
        let offset = view.bounds.height * (view.superview?.isFlipped == true ? -1 : 1)
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = appearing ? offset : 0
        slide.toValue = appearing ? 0 : offset
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        let animation = CAAnimationGroup()
        animation.animations = [slide, fade]
        animation.duration = Self.findBarAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        if !appearing {
            // The real bar has already closed, releasing focus and native search state.
            // This noninteractive image lasts only for the slide-out.
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            CATransaction.setCompletionBlock { [weak self, weak view] in
                view?.removeFromSuperview()
                if self?.departingFindBar === view { self?.departingFindBar = nil }
            }
        }
        layer.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
    }
}

private final class FindBarSnapshot: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSMenuItem {
    static func findAction(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "")
        item.tag = action.rawValue
        return item
    }
}
