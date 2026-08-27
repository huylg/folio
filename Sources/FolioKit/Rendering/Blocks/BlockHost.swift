import AppKit

/// What a block widget needs from its host: link routing, clipboard access, and a size cache
/// that outlives the widget's view.
public protocol BlockHost: AnyObject {
    var blockMetrics: DocumentMetrics { get }
    var sizeCache: BlockSizeCache { get }
    var diagramLayouts: DiagramLayoutCache { get }
    func blockRequestsOpen(_ destination: String)
    func blockRequestsCopy(_ text: String)
    /// Runs a shell block's source on a pty at the document's project root. `onOutput` fires
    /// on the main queue as output arrives, each time with the full transcript so far — parsed,
    /// so the console shows the command live *and* in the colors it asked for. `completion`
    /// fires on the main queue once the command exits, carrying its result so the card can log
    /// it inline — or nil from a host that does not execute (a peek card, a card with no
    /// document).
    func blockRequestsRun(_ command: String,
                          onOutput: @escaping (TerminalSnapshot) -> Void,
                          completion: @escaping (ProcessRunner.Output?) -> Void)
    /// A block's intrinsic height changed after it was placed — a run's output panel appeared
    /// or was dismissed — so the host must re-measure that component and reflow the page.
    func blockHeightDidChange(_ view: NSView)
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

    /// The cached height, without measuring — `nil` when this `(id, width)` was never
    /// measured. Lets a height-change report be checked for being height-neutral before it
    /// costs a page reflow.
    public func cachedHeight(for id: Int, width: CGFloat) -> CGFloat? {
        heights[Key(id: id, width: Int(width.rounded()))]
    }

    public func removeAll() { heights.removeAll() }

    public func remove(id: Int) {
        heights = heights.filter { $0.key.id != id }
    }
}

/// Caches resolved diagram geometry per `(source, width, metrics)`.
///
/// `BlockSizeCache` stores a `CGFloat`, so it can answer the measure pass but cannot feed the
/// draw pass — and without a second cache every diagram would be laid out twice, once to measure
/// and once to draw. This lives on the **host** for the same reason `BlockSizeCache` does: views
/// are built and destroyed as they scroll, while the geometry they were laid out against has to
/// stay stable. A `static` cache inside the engine would instead be global mutable state shared
/// by the app, the test suite and `--render-txt` over a whole vault, with no natural point to
/// invalidate it.
///
/// Keyed by the **source string** rather than a component index, because the measure path never
/// sees an index — and two identical diagrams in one document then share an entry, which is what
/// you want.
public final class DiagramLayoutCache {
    private struct Key: Hashable {
        let source: String
        let width: Int
        let fingerprint: String
    }

    /// Live resizing walks through many distinct widths, so the cache is bounded and evicts in
    /// insertion order.
    private static let capacity = 64

    private var layouts: [Key: LaidOutDiagram] = [:]
    private var insertion: [Key] = []

    /// How many layouts were actually computed. A test asserts this is 1 across a measure and a
    /// draw at the same width.
    public private(set) var misses = 0

    public init() {}

    public func layout(
        source: String,
        graph: DiagramGraph,
        width: CGFloat,
        metrics: DocumentMetrics
    ) -> LaidOutDiagram {
        let key = Key(source: source, width: Int(width.rounded()),
                      fingerprint: Self.fingerprint(metrics))
        if let cached = layouts[key] { return cached }
        misses += 1
        let value = DiagramLayout.layout(graph: graph, width: width, metrics: metrics)
        layouts[key] = value
        insertion.append(key)
        if insertion.count > Self.capacity {
            layouts.removeValue(forKey: insertion.removeFirst())
        }
        return value
    }

    public func removeAll() {
        layouts.removeAll()
        insertion.removeAll()
        misses = 0
    }

    /// `DocumentMetrics` is `Equatable` but not `Hashable`, and everything geometric about it is
    /// derived from these four values.
    private static func fingerprint(_ metrics: DocumentMetrics) -> String {
        "\(metrics.ramp.family.rawValue)|\(metrics.ramp.scale)|"
            + "\(metrics.lineWidth.rawValue)|\(metrics.density.rawValue)"
    }
}
