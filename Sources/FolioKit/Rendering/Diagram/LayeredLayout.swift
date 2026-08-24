import CoreGraphics

/// Sugiyama layered layout, in one canonical space: **rank grows downward, order grows
/// rightward**. Direction is applied afterwards as a single affine transform, so there is one
/// code path for all four directions rather than four that drift apart.
///
/// Layered rather than force-directed because Mermaid itself uses dagre, so the output reads the
/// way an author expects; because it needs no numerical solver; and — decisively — because it is
/// trivially deterministic once you refuse to iterate sets.
///
/// The determinism rules, which every function here obeys:
///
/// - No `Set` or `Dictionary` iteration drives geometry. Dictionaries are index maps only, and
///   the one place a `Set` appears it is counted, never walked.
/// - Every tie-break bottoms out in `(currentPosition, declarationOrder)` — two `Int`s, a total
///   ordering.
/// - Every loop has a fixed iteration cap. Nothing runs "until convergence".
/// - Rounding happens once, at the end, never inside an iterative loop.
enum LayeredLayout {

    // MARK: Output

    struct Node {
        /// Index into `DiagramGraph.nodes`, or nil for a virtual node on a long edge.
        let graphIndex: Int?
        /// Which edge this virtual node belongs to.
        let edgeIndex: Int?
        /// Spacing extent: what the rank packer reserves. A node with a self-loop reserves more
        /// than it draws, so the loop has somewhere to go.
        var across: CGFloat
        var along: CGFloat
        /// Drawn extent, never inflated. Keeping the two apart is what stops a self-loop from
        /// stretching the box it loops out of.
        let boxAcross: CGFloat
        let boxAlong: CGFloat
        var rank: Int
        var order: Int
        /// Centre, in canonical coordinates.
        var x: CGFloat = 0
        var y: CGFloat = 0
        let declOrder: Int
        var cluster: Int?
    }

    struct Edge {
        let graphIndex: Int
        /// How many ranks the author's dash count asks this edge to span.
        let minRankSpan: Int
        /// Layout-node indices, source first, after any cycle reversal was undone.
        var path: [Int]
        /// True when cycle removal flipped this edge; the arrowhead is restored at draw time.
        let reversed: Bool
        /// Where the label chip sits, in canonical coordinates. Nil when unlabelled.
        var labelCentre: CGPoint?
        var labelSize: CGSize
        /// Index within a group of parallel edges sharing the same endpoints, and the group size.
        var parallelIndex: Int
        var parallelCount: Int
        let isSelfLoop: Bool
    }

    struct Cluster {
        let graphIndex: Int
        var frame: CGRect
        /// False when the cluster's members could not be made contiguous. The nodes are still
        /// placed and every edge is still correct; only the box is withheld, because a box
        /// enclosing a foreign node states something untrue.
        var isDrawable: Bool
    }

    struct Result {
        var nodes: [Node]
        var edges: [Edge]
        var clusters: [Cluster]
        var size: CGSize
    }

    // MARK: Policy

    private static let orderingSweeps = 8
    private static let transposePasses = 4
    private static let coordinateSweeps = 8
    /// Virtual nodes pull far harder than real ones, which is what makes a long edge come out
    /// straight instead of stepping around every rank it passes.
    private static let virtualWeight: CGFloat = 8

    // MARK: Entry point

    static func layout(
        _ graph: DiagramGraph,
        direction: DiagramGraph.Direction,
        metrics: DiagramMetrics
    ) -> Result {
        var nodes = makeNodes(graph, direction: direction, metrics: metrics)
        let indexMap = graph.indexMap()

        var edges = makeEdges(graph, indexMap: indexMap, metrics: metrics, direction: direction)
        let selfLoops = edges.filter(\.isSelfLoop)
        for loop in selfLoops {
            guard let first = loop.path.first else { continue }
            // Twice, because the box stays centred in its cell: half the room lands on the side
            // the loop actually uses.
            nodes[first].across += metrics.selfLoopExtent * 2
        }

        var linked = edges.enumerated()
            .filter { !$0.element.isSelfLoop }
            .map { ($0.offset, $0.element) }
        reverseCycles(&linked, nodeCount: nodes.count)
        let ranks = rank(linked, nodeCount: nodes.count)
        for index in nodes.indices { nodes[index].rank = ranks[index] }

        insertVirtualNodes(&linked, nodes: &nodes, metrics: metrics, direction: direction)
        orderRanks(&nodes, links: linked)
        assignAcross(&nodes, links: linked, metrics: metrics)
        assignAlong(&nodes, links: linked, metrics: metrics, direction: direction)
        var size = normalise(&nodes)
        var clusters = makeClusters(graph, nodes: nodes, metrics: metrics)
        // A cluster's padding and title strip sit outside its members, so the box can reach past
        // the bounds the nodes alone established. Growing the canvas here is what keeps it from
        // being clipped by the card.
        size = accommodate(&nodes, clusters: &clusters, size: size)

        // Fold the resolved chains back onto the edges, undoing any cycle reversal so the path
        // always runs from the author's source to the author's target.
        for (edgeIndex, link) in linked {
            var path = link.path
            if link.reversed { path.reverse() }
            edges[edgeIndex].path = path
        }
        placeLabels(&edges, nodes: nodes)

        return Result(nodes: nodes, edges: edges, clusters: clusters, size: size)
    }

    // MARK: Construction

    private static func makeNodes(
        _ graph: DiagramGraph,
        direction: DiagramGraph.Direction,
        metrics: DiagramMetrics
    ) -> [Node] {
        graph.nodes.enumerated().map { index, node in
            let size = metrics.nodeSize(for: node, direction: direction)
            // A node's extent along the rank axis is its height when ranks run vertically and its
            // width when they run horizontally. Projecting once here is what lets everything
            // downstream be direction-agnostic.
            let across = direction.isVertical ? size.width : size.height
            let along = direction.isVertical ? size.height : size.width
            return Node(graphIndex: index, edgeIndex: nil, across: across, along: along,
                        boxAcross: across, boxAlong: along,
                        rank: 0, order: 0, declOrder: node.order, cluster: node.cluster)
        }
    }

    private static func makeEdges(
        _ graph: DiagramGraph,
        indexMap: [DiagramGraph.NodeID: Int],
        metrics: DiagramMetrics,
        direction: DiagramGraph.Direction
    ) -> [Edge] {
        // Parallel edges are grouped so they can be fanned apart later. The key is the unordered
        // endpoint pair, built as a string so the grouping cannot depend on hash order.
        var groupSizes: [String: Int] = [:]
        var groupIndex: [String: Int] = [:]

        func key(_ a: Int, _ b: Int) -> String { "\(min(a, b))-\(max(a, b))" }

        for edge in graph.edges {
            guard let from = indexMap[edge.from], let to = indexMap[edge.to] else { continue }
            groupSizes[key(from, to), default: 0] += 1
        }

        return graph.edges.enumerated().compactMap { index, edge in
            guard let from = indexMap[edge.from], let to = indexMap[edge.to] else { return nil }
            let k = key(from, to)
            let position = groupIndex[k] ?? 0
            groupIndex[k] = position + 1
            let labelSize = edge.label.map { metrics.edgeLabelSize($0) } ?? .zero
            return Edge(graphIndex: index, minRankSpan: edge.minRankSpan,
                        path: [from, to], reversed: false,
                        labelCentre: nil, labelSize: labelSize,
                        parallelIndex: position, parallelCount: groupSizes[k] ?? 1,
                        isSelfLoop: from == to)
        }
    }

    // MARK: Cycle removal

    /// Depth-first from every node in declaration order; any edge reaching a node still on the
    /// stack is reversed. Greedy rather than optimal — minimum feedback arc set is NP-hard — and
    /// the standard first pass of every layered layout.
    private static func reverseCycles(_ links: inout [(Int, Edge)], nodeCount: Int) {
        // Copied into plain arrays first: the walk is recursive, and a nested recursive function
        // may not capture an `inout` parameter.
        let endpoints = links.map { ($0.1.path[0], $0.1.path[1]) }
        var outgoing = [[Int]](repeating: [], count: nodeCount)
        for (position, pair) in endpoints.enumerated() { outgoing[pair.0].append(position) }

        var state = [Int](repeating: 0, count: nodeCount)   // 0 fresh, 1 on stack, 2 finished
        var reversed = [Bool](repeating: false, count: links.count)

        func visit(_ node: Int) {
            state[node] = 1
            for position in outgoing[node] {
                guard !reversed[position] else { continue }
                let target = endpoints[position].1
                if state[target] == 1 {
                    reversed[position] = true
                } else if state[target] == 0 {
                    visit(target)
                }
            }
            state[node] = 2
        }

        for node in 0..<nodeCount where state[node] == 0 { visit(node) }

        for position in links.indices where reversed[position] {
            let link = links[position].1
            links[position].1 = Edge(graphIndex: link.graphIndex,
                                     minRankSpan: link.minRankSpan,
                                     path: [link.path[1], link.path[0]],
                                     reversed: true,
                                     labelCentre: nil, labelSize: link.labelSize,
                                     parallelIndex: link.parallelIndex,
                                     parallelCount: link.parallelCount,
                                     isSelfLoop: false)
        }
    }

    // MARK: Ranking

    /// Longest path, then one slack-tightening pass so a lone source does not float above the
    /// rank it feeds. Network simplex would give marginally tighter ranks for a great deal more
    /// code; this is the trade every small layered renderer makes.
    private static func rank(_ links: [(Int, Edge)], nodeCount count: Int) -> [Int] {
        var ranks = [Int](repeating: 0, count: count)
        var indegree = [Int](repeating: 0, count: count)
        var outgoing = [[Int]](repeating: [], count: count)

        for (position, link) in links.enumerated() {
            let from = link.1.path[0], to = link.1.path[1]
            outgoing[from].append(position)
            indegree[to] += 1
        }

        // Kahn's algorithm, always taking the lowest-numbered ready node so the traversal order
        // is a function of declaration order alone.
        var ready = (0..<count).filter { indegree[$0] == 0 }
        var visited = 0
        while let node = ready.min() {
            ready.removeAll { $0 == node }
            visited += 1
            for position in outgoing[node] {
                let edge = links[position].1
                let to = edge.path[1]
                ranks[to] = max(ranks[to], ranks[node] + edge.minRankSpan)
                indegree[to] -= 1
                if indegree[to] == 0 { ready.append(to) }
            }
        }
        // A residual cycle cannot happen after `reverseCycles`, but if it ever did the ranks
        // above are still finite and monotone enough to draw.
        _ = visited

        var incoming = [Int](repeating: 0, count: count)
        for (_, link) in links { incoming[link.path[1]] += 1 }
        for node in 0..<count where incoming[node] == 0 && !outgoing[node].isEmpty {
            let tightest = outgoing[node].map { position -> Int in
                let edge = links[position].1
                return ranks[edge.path[1]] - edge.minRankSpan
            }.min()
            if let tightest, tightest > ranks[node] { ranks[node] = tightest }
        }
        return ranks
    }

    // MARK: Virtual nodes

    /// Every edge crossing more than one rank gets a chain of placeholders, one per intermediate
    /// rank. They are what make a long edge route *around* the ranks it passes rather than
    /// through them, and they are also where a multi-rank edge parks its label chip.
    private static func insertVirtualNodes(
        _ links: inout [(Int, Edge)],
        nodes: inout [Node],
        metrics: DiagramMetrics,
        direction: DiagramGraph.Direction
    ) {
        for position in links.indices {
            let edge = links[position].1
            let from = edge.path[0], to = edge.path[1]
            let gap = nodes[to].rank - nodes[from].rank
            guard gap > 1 else { continue }

            var path = [from]
            for step in 1..<gap {
                // The first placeholder carries the label, so it reserves the chip's width.
                let carriesLabel = step == 1 && edge.labelSize != .zero
                let chipAcross = direction.isVertical ? edge.labelSize.width : edge.labelSize.height
                let across = carriesLabel
                    ? max(metrics.virtualNodeExtent, chipAcross)
                    : metrics.virtualNodeExtent
                nodes.append(Node(graphIndex: nil, edgeIndex: edge.graphIndex,
                                  across: across, along: 0,
                                  boxAcross: 0, boxAlong: 0,
                                  rank: nodes[from].rank + step, order: 0,
                                  declOrder: nodes.count, cluster: nodes[from].cluster))
                path.append(nodes.count - 1)
            }
            path.append(to)
            links[position].1.path = path
        }
    }

    // MARK: Ordering

    private static func ranksOf(_ nodes: [Node]) -> [[Int]] {
        let maxRank = nodes.map(\.rank).max() ?? 0
        var layers = [[Int]](repeating: [], count: maxRank + 1)
        for (index, node) in nodes.enumerated() { layers[node.rank].append(index) }
        return layers
    }

    /// Median heuristic sweeps, each followed by transpose. The best ordering seen wins, and a
    /// tie keeps the earlier one — which is what stops two equally good orderings from
    /// alternating between runs.
    private static func orderRanks(_ nodes: inout [Node], links: [(Int, Edge)]) {
        var layers = ranksOf(nodes)
        guard layers.count > 1 else {
            writeBack(&nodes, layers: layers)
            return
        }

        // Adjacency over the *segmented* graph: each consecutive pair in a chain is one link.
        var successors = [[Int]](repeating: [], count: nodes.count)
        var predecessors = [[Int]](repeating: [], count: nodes.count)
        for (_, link) in links {
            for step in 0..<(link.path.count - 1) {
                let a = link.path[step], b = link.path[step + 1]
                successors[a].append(b)
                predecessors[b].append(a)
            }
        }

        seedOrder(&layers, successors: successors, nodes: nodes)
        var best = layers
        var bestCrossings = crossings(layers, successors: successors)

        for sweep in 0..<orderingSweeps {
            let downward = sweep % 2 == 0
            let range = downward
                ? Array(1..<layers.count)
                : Array((0..<(layers.count - 1)).reversed())
            for rank in range {
                let neighbours = downward ? predecessors : successors
                let reference = downward ? layers[rank - 1] : layers[rank + 1]
                layers[rank] = medianSorted(layers[rank], reference: reference,
                                            neighbours: neighbours, nodes: nodes)
            }
            compactClusters(&layers, nodes: nodes)
            transpose(&layers, successors: successors)

            let score = crossings(layers, successors: successors)
            if score < bestCrossings {
                bestCrossings = score
                best = layers
            }
            if bestCrossings == 0 { break }
        }
        writeBack(&nodes, layers: best)
    }

    private static func writeBack(_ nodes: inout [Node], layers: [[Int]]) {
        for layer in layers {
            for (position, node) in layer.enumerated() { nodes[node].order = position }
        }
    }

    /// Breadth-first from the rank-0 nodes in declaration order. A good start matters more than
    /// any single sweep, and this one is cheap and stable.
    private static func seedOrder(_ layers: inout [[Int]], successors: [[Int]], nodes: [Node]) {
        var seen = [Bool](repeating: false, count: nodes.count)
        var ordered = [[Int]](repeating: [], count: layers.count)
        var queue: [Int] = layers.first?.sorted { nodes[$0].declOrder < nodes[$1].declOrder } ?? []
        for node in queue { seen[node] = true }

        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            ordered[nodes[node].rank].append(node)
            for next in successors[node] where !seen[next] {
                seen[next] = true
                queue.append(next)
            }
        }
        for (rank, layer) in layers.enumerated() {
            for node in layer where !seen[node] { ordered[rank].append(node) }
        }
        layers = ordered
    }

    private static func medianSorted(
        _ layer: [Int], reference: [Int], neighbours: [[Int]], nodes: [Node]
    ) -> [Int] {
        var position: [Int: Int] = [:]
        for (index, node) in reference.enumerated() { position[node] = index }

        let keyed = layer.enumerated().map { current, node -> (CGFloat, Int, Int) in
            let places = neighbours[node].compactMap { position[$0] }.sorted()
            guard !places.isEmpty else {
                // No neighbour in the reference rank: hold station. dagre's `-1` rule, expressed
                // as "your key is where you already are".
                return (CGFloat(current), current, nodes[node].declOrder)
            }
            let middle = places.count / 2
            let median = places.count % 2 == 1
                ? CGFloat(places[middle])
                : CGFloat(places[middle - 1] + places[middle]) / 2
            return (median, current, nodes[node].declOrder)
        }

        let order = zip(layer, keyed).sorted { a, b in
            if a.1.0 != b.1.0 { return a.1.0 < b.1.0 }
            if a.1.1 != b.1.1 { return a.1.1 < b.1.1 }
            return a.1.2 < b.1.2
        }
        return order.map(\.0)
    }

    /// Nudges a cluster's members together around their median position. A bias, not a
    /// guarantee: whether the box can actually be drawn is decided later by a contiguity check.
    private static func compactClusters(_ layers: inout [[Int]], nodes: [Node]) {
        for rank in layers.indices {
            let layer = layers[rank]
            guard layer.count > 2 else { continue }
            let grouped = layer.enumerated().sorted { a, b in
                let ca = nodes[a.element].cluster ?? -1
                let cb = nodes[b.element].cluster ?? -1
                if ca != cb {
                    // Order clusters by where their members already sit, so compaction moves
                    // nodes the shortest distance rather than reshuffling the rank.
                    let ma = medianPosition(of: ca, in: layer, nodes: nodes)
                    let mb = medianPosition(of: cb, in: layer, nodes: nodes)
                    if ma != mb { return ma < mb }
                    return ca < cb
                }
                return a.offset < b.offset
            }
            layers[rank] = grouped.map(\.element)
        }
    }

    private static func medianPosition(of cluster: Int, in layer: [Int], nodes: [Node]) -> CGFloat {
        let places = layer.enumerated()
            .filter { (nodes[$0.element].cluster ?? -1) == cluster }
            .map { CGFloat($0.offset) }
        guard !places.isEmpty else { return 0 }
        return places.reduce(0, +) / CGFloat(places.count)
    }

    /// Swaps adjacent pairs while it strictly reduces crossings. Strictly, so it cannot cycle.
    private static func transpose(_ layers: inout [[Int]], successors: [[Int]]) {
        for _ in 0..<transposePasses {
            var improved = false
            for rank in layers.indices where layers[rank].count > 1 {
                for position in 0..<(layers[rank].count - 1) {
                    let before = localCrossings(layers, rank: rank, successors: successors)
                    layers[rank].swapAt(position, position + 1)
                    let after = localCrossings(layers, rank: rank, successors: successors)
                    if after < before {
                        improved = true
                    } else {
                        layers[rank].swapAt(position, position + 1)
                    }
                }
            }
            if !improved { break }
        }
    }

    private static func localCrossings(_ layers: [[Int]], rank: Int, successors: [[Int]]) -> Int {
        var total = 0
        if rank > 0 { total += crossings(between: layers[rank - 1], layers[rank], successors) }
        if rank + 1 < layers.count {
            total += crossings(between: layers[rank], layers[rank + 1], successors)
        }
        return total
    }

    private static func crossings(_ layers: [[Int]], successors: [[Int]]) -> Int {
        var total = 0
        for rank in 0..<max(0, layers.count - 1) {
            total += crossings(between: layers[rank], layers[rank + 1], successors)
        }
        return total
    }

    private static func crossings(between upper: [Int], _ lower: [Int], _ successors: [[Int]]) -> Int {
        var lowerPosition: [Int: Int] = [:]
        for (index, node) in lower.enumerated() { lowerPosition[node] = index }

        var pairs: [(Int, Int)] = []
        for (upperIndex, node) in upper.enumerated() {
            for next in successors[node] {
                guard let lowerIndex = lowerPosition[next] else { continue }
                pairs.append((upperIndex, lowerIndex))
            }
        }
        // Inversion count. O(k²), and k is the number of edges between two adjacent ranks — a
        // handful in any diagram a reader can follow.
        var total = 0
        for i in 0..<pairs.count {
            for j in (i + 1)..<pairs.count {
                let a = pairs[i], b = pairs[j]
                if (a.0 < b.0 && a.1 > b.1) || (a.0 > b.0 && a.1 < b.1) { total += 1 }
            }
        }
        return total
    }

    // MARK: Across coordinates

    /// Each rank is solved exactly, not nudged.
    ///
    /// Given a desired position per node and the separation the boxes require, the best ordered
    /// assignment is an isotonic regression, which pool-adjacent-violators solves optimally in
    /// one linear pass. That is both shorter and better behaved than the usual
    /// push-your-neighbour loop, and it cannot oscillate between sweeps.
    private static func assignAcross(_ nodes: inout [Node], links: [(Int, Edge)],
                                     metrics: DiagramMetrics) {
        let layers = ranksOf(nodes)
        var successors = [[Int]](repeating: [], count: nodes.count)
        var predecessors = [[Int]](repeating: [], count: nodes.count)
        for (_, link) in links {
            for step in 0..<(link.path.count - 1) {
                successors[link.path[step]].append(link.path[step + 1])
                predecessors[link.path[step + 1]].append(link.path[step])
            }
        }

        // Initial pass: pack every rank tight against its left edge.
        for layer in layers {
            var cursor: CGFloat = 0
            for node in layer {
                nodes[node].x = cursor + nodes[node].across / 2
                cursor += nodes[node].across + metrics.nodeGap
            }
        }

        for sweep in 0..<coordinateSweeps {
            let downward = sweep % 2 == 0
            let order = downward
                ? Array(layers.indices)
                : Array(layers.indices.reversed())
            for rank in order {
                let neighbours = downward ? predecessors : successors
                let desired = layers[rank].map { node -> CGFloat in
                    let places = neighbours[node].map { nodes[$0].x }.sorted()
                    guard !places.isEmpty else { return nodes[node].x }
                    let middle = places.count / 2
                    return places.count % 2 == 1
                        ? places[middle]
                        : (places[middle - 1] + places[middle]) / 2
                }
                let weights = layers[rank].map { nodes[$0].graphIndex == nil ? virtualWeight : 1 }
                let solved = isotonic(desired: desired, weights: weights,
                                      gaps: gaps(layers[rank], nodes: nodes, metrics: metrics))
                for (index, node) in layers[rank].enumerated() { nodes[node].x = solved[index] }
            }
        }

        // Centre every rank on the widest one, so a two-node rank does not sit hard left under a
        // six-node rank above it.
        var minimum = CGFloat.greatestFiniteMagnitude
        var maximum = -CGFloat.greatestFiniteMagnitude
        for node in nodes {
            minimum = min(minimum, node.x - node.across / 2)
            maximum = max(maximum, node.x + node.across / 2)
        }
        guard maximum > minimum else { return }
        let centre = (minimum + maximum) / 2
        for layer in layers {
            guard let first = layer.first, let last = layer.last else { continue }
            let left = nodes[first].x - nodes[first].across / 2
            let right = nodes[last].x + nodes[last].across / 2
            let shift = centre - (left + right) / 2
            for node in layer { nodes[node].x += shift }
        }
    }

    /// Minimum centre-to-centre distance between consecutive nodes in a rank. Two nodes in
    /// different clusters need the two boxes' padding between them as well.
    private static func gaps(_ layer: [Int], nodes: [Node], metrics: DiagramMetrics) -> [CGFloat] {
        guard layer.count > 1 else { return [] }
        return (0..<(layer.count - 1)).map { index in
            let a = nodes[layer[index]], b = nodes[layer[index + 1]]
            var gap = (a.across + b.across) / 2 + metrics.nodeGap
            if a.cluster != b.cluster { gap += metrics.clusterPadding * 2 }
            return gap
        }
    }

    /// Weighted isotonic regression by pool-adjacent-violators.
    ///
    /// Solves "put each node as near its desired position as possible, in this order, at least
    /// `gaps[i]` apart" exactly. The change of variable `z = x - cumulativeGap` turns the
    /// separation constraints into a plain non-decreasing constraint, which is what PAVA solves.
    private static func isotonic(desired: [CGFloat], weights: [CGFloat],
                                 gaps: [CGFloat]) -> [CGFloat] {
        guard !desired.isEmpty else { return [] }
        var offsets = [CGFloat](repeating: 0, count: desired.count)
        for index in 1..<desired.count { offsets[index] = offsets[index - 1] + gaps[index - 1] }
        let targets = zip(desired, offsets).map { $0 - $1 }

        // Each block holds a pooled weighted mean over a contiguous run.
        var blockValue: [CGFloat] = []
        var blockWeight: [CGFloat] = []
        var blockCount: [Int] = []

        for index in targets.indices {
            blockValue.append(targets[index])
            blockWeight.append(weights[index])
            blockCount.append(1)
            while blockValue.count > 1, blockValue[blockValue.count - 2] > blockValue[blockValue.count - 1] {
                let w1 = blockWeight[blockWeight.count - 2], w2 = blockWeight[blockWeight.count - 1]
                let merged = (blockValue[blockValue.count - 2] * w1
                              + blockValue[blockValue.count - 1] * w2) / (w1 + w2)
                blockValue.removeLast(); blockValue[blockValue.count - 1] = merged
                blockWeight.removeLast(); blockWeight[blockWeight.count - 1] = w1 + w2
                let count = blockCount.removeLast()
                blockCount[blockCount.count - 1] += count
            }
        }

        var result: [CGFloat] = []
        for (index, value) in blockValue.enumerated() {
            result.append(contentsOf: [CGFloat](repeating: value, count: blockCount[index]))
        }
        return zip(result, offsets).map { $0 + $1 }
    }

    // MARK: Along coordinates

    /// Rank positions along the flow. The gap grows where a single-rank edge carries a label —
    /// the chip has to fit between the two ranks it spans — and where a cluster boundary needs
    /// its padding and title strip.
    private static func assignAlong(
        _ nodes: inout [Node], links: [(Int, Edge)], metrics: DiagramMetrics,
        direction: DiagramGraph.Direction
    ) {
        let layers = ranksOf(nodes)
        var extents = layers.map { layer in layer.map { nodes[$0].along }.max() ?? 0 }
        if extents.isEmpty { extents = [0] }

        var extraGap = [CGFloat](repeating: 0, count: max(0, layers.count - 1))
        for (_, link) in links where link.path.count == 2 && link.labelSize != .zero {
            let rank = nodes[link.path[0]].rank
            guard rank < extraGap.count else { continue }
            let chipAlong = direction.isVertical ? link.labelSize.height : link.labelSize.width
            extraGap[rank] = max(extraGap[rank], chipAlong + metrics.labelChipPadding.height * 2)
        }
        for rank in extraGap.indices {
            // Counting how many clusters change between two ranks; a count is independent of any
            // iteration order, which is why a Set is safe here.
            let above = Set(layers[rank].compactMap { nodes[$0].cluster })
            let below = Set(layers[rank + 1].compactMap { nodes[$0].cluster })
            let changed = above.symmetricDifference(below).count
            if changed > 0 {
                extraGap[rank] += metrics.clusterPadding * 2
                    + (below.subtracting(above).isEmpty ? 0 : metrics.clusterTitleHeight)
            }
        }

        var origins = [CGFloat](repeating: 0, count: layers.count)
        var cursor: CGFloat = 0
        for rank in layers.indices {
            origins[rank] = cursor
            cursor += extents[rank]
            if rank < extraGap.count { cursor += metrics.rankGap + extraGap[rank] }
        }
        for (rank, layer) in layers.enumerated() {
            for node in layer {
                nodes[node].y = origins[rank] + extents[rank] / 2
            }
        }
    }

    // MARK: Labels

    private static func placeLabels(_ edges: inout [Edge], nodes: [Node]) {
        for index in edges.indices where edges[index].labelSize != .zero {
            let path = edges[index].path
            guard path.count >= 2 else { continue }
            if path.count > 2 {
                // Park the chip on the first placeholder, whose extent was widened for it.
                let virtual = path[1]
                edges[index].labelCentre = CGPoint(x: nodes[virtual].x, y: nodes[virtual].y)
            } else {
                let a = nodes[path[0]], b = nodes[path[1]]
                edges[index].labelCentre = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
        }
    }

    // MARK: Normalisation

    /// Shifts everything to the origin and reports the canonical canvas size. This is the one and
    /// only rounding pass.
    private static func normalise(_ nodes: inout [Node]) -> CGSize {
        guard !nodes.isEmpty else { return .zero }
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for node in nodes {
            minX = min(minX, node.x - node.across / 2)
            maxX = max(maxX, node.x + node.across / 2)
            minY = min(minY, node.y - node.along / 2)
            maxY = max(maxY, node.y + node.along / 2)
        }
        for index in nodes.indices {
            nodes[index].x = (nodes[index].x - minX).rounded()
            nodes[index].y = (nodes[index].y - minY).rounded()
        }
        return CGSize(width: (maxX - minX).rounded(.up), height: (maxY - minY).rounded(.up))
    }

    /// Expands the canvas to hold every cluster box, shifting the contents if a box reached
    /// above or left of the origin.
    private static func accommodate(_ nodes: inout [Node], clusters: inout [Cluster],
                                    size: CGSize) -> CGSize {
        let boxes = clusters.filter(\.isDrawable).map(\.frame)
        guard !boxes.isEmpty else { return size }
        var bounds = CGRect(origin: .zero, size: size)
        for box in boxes { bounds = bounds.union(box) }
        guard bounds != CGRect(origin: .zero, size: size) else { return size }

        let shiftX = -bounds.minX
        let shiftY = -bounds.minY
        for index in nodes.indices {
            nodes[index].x += shiftX
            nodes[index].y += shiftY
        }
        for index in clusters.indices {
            clusters[index].frame = clusters[index].frame.offsetBy(dx: shiftX, dy: shiftY)
        }
        return CGSize(width: bounds.width.rounded(.up), height: bounds.height.rounded(.up))
    }

    // MARK: Clusters

    private static func makeClusters(
        _ graph: DiagramGraph, nodes: [Node], metrics: DiagramMetrics
    ) -> [Cluster] {
        guard !graph.clusters.isEmpty else { return [] }
        var descendants = [[Int]](repeating: [], count: graph.clusters.count)
        for (index, node) in nodes.enumerated() {
            guard let graphIndex = node.graphIndex,
                  var cluster = graph.nodes[graphIndex].cluster else { continue }
            while true {
                descendants[cluster].append(index)
                guard let parent = graph.clusters[cluster].parent else { break }
                cluster = parent
            }
        }

        return graph.clusters.indices.map { index in
            let members = descendants[index]
            guard !members.isEmpty else {
                return Cluster(graphIndex: index, frame: .zero, isDrawable: false)
            }
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for member in members {
                let node = nodes[member]
                minX = min(minX, node.x - node.across / 2)
                maxX = max(maxX, node.x + node.across / 2)
                minY = min(minY, node.y - node.along / 2)
                maxY = max(maxY, node.y + node.along / 2)
            }
            let padding = metrics.clusterPadding
            let title = graph.clusters[index].title == nil ? 0 : metrics.clusterTitleHeight
            let frame = CGRect(x: minX - padding, y: minY - padding - title,
                               width: (maxX - minX) + padding * 2,
                               height: (maxY - minY) + padding * 2 + title)
            return Cluster(graphIndex: index, frame: frame,
                           isDrawable: isContiguous(members, nodes: nodes, frame: frame))
        }
    }

    /// A box may only be drawn when no node outside the cluster falls inside it. Otherwise the
    /// box would claim a node that is not a member, which states something untrue about the
    /// diagram — so the nodes stay where they are and the box is simply withheld.
    private static func isContiguous(_ members: [Int], nodes: [Node], frame: CGRect) -> Bool {
        let inside = Set(members)
        for (index, node) in nodes.enumerated() where !inside.contains(index) {
            guard node.graphIndex != nil else { continue }
            let rect = CGRect(x: node.x - node.across / 2, y: node.y - node.along / 2,
                              width: node.across, height: node.along)
            if frame.intersects(rect.insetBy(dx: 1, dy: 1)) { return false }
        }
        return true
    }
}
