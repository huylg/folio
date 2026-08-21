import AppKit

/// What a block widget needs from its host: link routing, clipboard access, and a size cache
/// that outlives the widget's view.
public protocol BlockHost: AnyObject {
    var blockMetrics: DocumentMetrics { get }
    var sizeCache: BlockSizeCache { get }
    func blockRequestsOpen(_ destination: String)
    func blockRequestsCopy(_ text: String)
    /// Bumped while a widget has asynchronous work outstanding, so headless snapshots can wait
    /// for quiescence instead of capturing placeholders.
    var pendingWorkCount: Int { get set }
}

/// Caches measured component heights per `(id, width)`.
///
/// It lives on the **host** rather than on a view, because the document stack creates and
/// destroys component views as they scroll in and out of the viewport, while the heights they
/// were laid out against have to stay stable: the stack positions every component from these
/// numbers, so a height that changed under it would move content the reader is looking at.
public final class BlockSizeCache {
    private struct Key: Hashable {
        let id: Int
        let width: Int
    }
    private var heights: [Key: CGFloat] = [:]

    public init() {}

    public func height(for id: Int, width: CGFloat, measure: () -> CGFloat) -> CGFloat {
        let key = Key(id: id, width: Int(width.rounded()))
        if let cached = heights[key] { return cached }
        let value = measure()
        heights[key] = value
        return value
    }

    public func removeAll() { heights.removeAll() }

    public func remove(id: Int) {
        heights = heights.filter { $0.key.id != id }
    }
}
