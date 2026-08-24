import Foundation

/// Accumulates nodes, edges and clusters in declaration order.
///
/// Shared by both dialects, because a state diagram is a directed graph with different shapes and
/// nothing else. Keeping one builder is what lets `LayeredLayout` stay dialect-agnostic.
final class GraphBuilder {

    private struct Slot {
        var label: DiagramGraph.Label
        var shape: DiagramGraph.Shape
        var classes: [String]
        var cluster: Int?
        var order: Int
        /// Whether an explicit bracket or `state … as …` set the shape. A later bare mention in a
        /// chain must not downgrade it — chains re-mention ids constantly.
        var isDeclared: Bool
    }

    private var slots: [DiagramGraph.NodeID: Slot] = [:]
    private var nodeOrder: [DiagramGraph.NodeID] = []
    private var edges: [DiagramGraph.Edge] = []
    private var clusters: [DiagramGraph.Cluster] = []
    private var clusterMembers: [[DiagramGraph.NodeID]] = []
    private var openClusters: [Int] = []
    private(set) var classNames: [String] = []

    var openClusterDepth: Int { openClusters.count }
    var hasOpenCluster: Bool { !openClusters.isEmpty }
    var nodeCount: Int { nodeOrder.count }

    /// Records a mention of `id`. An explicit shape or label only lands the first time one is
    /// given; everything after that is a reference.
    @discardableResult
    func mention(
        _ id: DiagramGraph.NodeID,
        shape: DiagramGraph.Shape? = nil,
        label: DiagramGraph.Label? = nil,
        classes: [String] = []
    ) -> Bool {
        if var slot = slots[id] {
            if let shape, !slot.isDeclared {
                slot.shape = shape
                slot.isDeclared = true
            }
            if let label, !label.isEmpty, slot.label.isEmpty { slot.label = label }
            for name in classes where !slot.classes.contains(name) { slot.classes.append(name) }
            slots[id] = slot
            return true
        }
        guard nodeOrder.count < DiagramBudget.maxNodes else { return false }
        let cluster = openClusters.last
        slots[id] = Slot(
            label: label ?? DiagramGraph.Label(lines: [id.raw]),
            shape: shape ?? .rect,
            classes: classes,
            cluster: cluster,
            order: nodeOrder.count,
            isDeclared: shape != nil
        )
        nodeOrder.append(id)
        if let cluster { clusterMembers[cluster].append(id) }
        return true
    }

    /// Overrides a node's shape unconditionally. Used for state pseudo-states, where the shape
    /// comes from the syntax rather than from a bracket.
    func forceShape(_ id: DiagramGraph.NodeID, _ shape: DiagramGraph.Shape) {
        guard var slot = slots[id] else { return }
        slot.shape = shape
        slot.isDeclared = true
        slots[id] = slot
    }

    func setLabel(_ id: DiagramGraph.NodeID, _ label: DiagramGraph.Label) {
        guard var slot = slots[id] else { return }
        slot.label = label
        slots[id] = slot
    }

    func addClasses(_ names: [String], to id: DiagramGraph.NodeID) {
        guard var slot = slots[id] else { return }
        for name in names where !slot.classes.contains(name) { slot.classes.append(name) }
        slots[id] = slot
    }

    func declareClass(_ name: String) {
        guard !name.isEmpty, !classNames.contains(name) else { return }
        classNames.append(name)
    }

    @discardableResult
    func connect(
        from: DiagramGraph.NodeID,
        to: DiagramGraph.NodeID,
        label: DiagramGraph.Label?,
        stroke: DiagramGraph.Stroke,
        head: DiagramGraph.Cap,
        tail: DiagramGraph.Cap,
        minRankSpan: Int
    ) -> Bool {
        guard edges.count < DiagramBudget.maxEdges else { return false }
        edges.append(DiagramGraph.Edge(from: from, to: to, label: label, stroke: stroke,
                                       head: head, tail: tail, minRankSpan: minRankSpan,
                                       order: edges.count))
        return true
    }

    /// Opens a cluster. Returns false past the nesting ceiling, which the caller turns into a
    /// refusal rather than a silently flattened diagram.
    func openCluster(id: String, title: DiagramGraph.Label?) -> Bool {
        guard openClusters.count < DiagramBudget.maxClusterDepth else { return false }
        let index = clusters.count
        clusters.append(DiagramGraph.Cluster(id: id, title: title, parent: openClusters.last,
                                             members: [], order: index))
        clusterMembers.append([])
        openClusters.append(index)
        return true
    }

    @discardableResult
    func closeCluster() -> Bool {
        guard !openClusters.isEmpty else { return false }
        openClusters.removeLast()
        return true
    }

    func build(kind: DiagramGraph.Kind, direction: DiagramGraph.Direction) -> DiagramGraph? {
        guard openClusters.isEmpty else { return nil }
        let nodes = nodeOrder.compactMap { id -> DiagramGraph.Node? in
            guard let slot = slots[id] else { return nil }
            return DiagramGraph.Node(id: id, label: slot.label, shape: slot.shape,
                                     classes: slot.classes, cluster: slot.cluster,
                                     order: slot.order)
        }
        let resolved = clusters.enumerated().map { index, cluster in
            DiagramGraph.Cluster(id: cluster.id, title: cluster.title, parent: cluster.parent,
                                 members: clusterMembers[index], order: cluster.order)
        }
        // A cluster nobody joined draws an empty box. Drop it rather than draw nothing inside it.
        let kept = resolved.filter { !$0.members.isEmpty }
        return DiagramGraph(kind: kind, direction: direction, nodes: nodes, edges: edges,
                            clusters: kept.count == resolved.count ? resolved : renumber(kept),
                            classNames: classNames)
    }

    /// Dropping an empty cluster invalidates every later index, so parents and node references
    /// are remapped rather than left dangling.
    private func renumber(_ kept: [DiagramGraph.Cluster]) -> [DiagramGraph.Cluster] {
        var remap: [Int: Int] = [:]
        for (newIndex, cluster) in kept.enumerated() { remap[cluster.order] = newIndex }
        let result = kept.enumerated().map { newIndex, cluster in
            DiagramGraph.Cluster(id: cluster.id, title: cluster.title,
                                 parent: cluster.parent.flatMap { remap[$0] },
                                 members: cluster.members, order: newIndex)
        }
        for id in nodeOrder {
            guard var slot = slots[id], let old = slot.cluster else { continue }
            slot.cluster = remap[old]
            slots[id] = slot
        }
        return result
    }
}

/// Reads the `flowchart` / `graph` dialect.
///
/// A whitelist: any statement that does not match a production here makes the whole diagram
/// unavailable, and the reader gets the source card. Drawing three quarters of a diagram is worse
/// than drawing none of it.
///
/// **Declared styling is deliberately discarded.** `classDef fill:#f9f,stroke:#333` names colors
/// that would be invisible on Folio's dark canvas, and hardcoded color values are exactly what
/// `Theme.swift` forbids. What survives is the *fact* that a node carries a class, which the
/// renderer turns into a theme-derived tint. `classDef` and `:::` are still parsed structurally
/// and not optionally — without handling `:::`, `A:::hot[Label]` mis-parses the id, which is a
/// correctness bug rather than a styling one.
enum MermaidFlowchartParser {

    static func parse(
        _ statements: [MermaidToken.Statement],
        direction: DiagramGraph.Direction
    ) -> DiagramGraph? {
        let builder = GraphBuilder()

        for statement in statements {
            let text = statement.text
            let first = text
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first
                .map { String($0).lowercased() } ?? ""

            switch first {
            case "subgraph":
                guard openSubgraph(text, into: builder) else { return nil }
            case "end":
                guard text.count == 3, builder.closeCluster() else { return nil }
            case "direction":
                // An inner direction is understood and ignored: honouring it would need a
                // per-cluster layout pass, which is not in this pass's scope.
                continue
            case "classdef":
                guard declareClass(text, into: builder) else { return nil }
            case "class":
                guard assignClass(text, into: builder) else { return nil }
            case "style", "linkstyle", "click":
                // Recognised and skipped. Losing an interaction directive in a reader is fine;
                // losing the diagram is not.
                continue
            default:
                if text.hasPrefix("accTitle") || text.hasPrefix("accDescr") { continue }
                guard parseChain(text, into: builder) else { return nil }
            }
        }
        return builder.build(kind: .flowchart, direction: direction)
    }

    // MARK: Statements

    private static func openSubgraph(_ text: String, into builder: GraphBuilder) -> Bool {
        let rest = String(text.dropFirst("subgraph".count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return builder.openCluster(id: "", title: nil) }

        let chars = Array(rest)
        guard let (id, after) = MermaidToken.scanIdentifier(chars, from: 0) else {
            // `subgraph [Title]` with no id.
            if let scan = MermaidToken.scanBracketed(chars, from: 0) {
                return builder.openCluster(id: "", title: MermaidToken.decodeLabel(scan.body))
            }
            return false
        }
        var cursor = after
        while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
        if let scan = MermaidToken.scanBracketed(chars, from: cursor), scan.end == chars.count {
            return builder.openCluster(id: id, title: MermaidToken.decodeLabel(scan.body))
        }
        // `subgraph Some Title` — the whole remainder is the title, and also its id.
        return builder.openCluster(id: rest, title: MermaidToken.decodeLabel(rest))
    }

    private static func declareClass(_ text: String, into builder: GraphBuilder) -> Bool {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { return false }
        for name in parts[1].split(separator: ",") {
            builder.declareClass(String(name).trimmingCharacters(in: .whitespaces))
        }
        return true
    }

    private static func assignClass(_ text: String, into builder: GraphBuilder) -> Bool {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 3 else { return false }
        let names = parts[2].split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        for name in names { builder.declareClass(name) }
        for raw in parts[1].split(separator: ",") {
            let id = DiagramGraph.NodeID(String(raw).trimmingCharacters(in: .whitespaces))
            guard builder.mention(id) else { return false }
            builder.addClasses(names, to: id)
        }
        return true
    }

    // MARK: Chains

    /// `A --> B --> C`, `A --> B & C --> D`, or a bare `A[Label]` declaration.
    ///
    /// `&` groups form a product: `A --> B & C` connects A to both, and `A & B --> C & D` draws
    /// all four edges. That is Mermaid's rule and it is what authors rely on for fan-in.
    private static func parseChain(_ text: String, into builder: GraphBuilder) -> Bool {
        let chars = Array(text)
        var cursor = 0
        var previous: [DiagramGraph.NodeID] = []
        var pending: MermaidToken.EdgeScan?
        var pendingLabel: DiagramGraph.Label?

        while true {
            guard let (group, next) = parseGroup(chars, from: cursor, into: builder) else {
                return false
            }
            cursor = next

            if let scan = pending {
                for from in previous {
                    for to in group {
                        guard builder.connect(from: from, to: to, label: pendingLabel,
                                              stroke: scan.stroke, head: scan.head,
                                              tail: scan.tail,
                                              minRankSpan: scan.minRankSpan) else { return false }
                    }
                }
            }
            previous = group
            pending = nil
            pendingLabel = nil

            while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
                cursor += 1
            }
            if cursor >= chars.count { return true }

            guard let scan = MermaidToken.scanEdge(chars, from: cursor) else { return false }
            cursor = scan.end
            var label = scan.inlineLabel
            if let (piped, after) = MermaidToken.scanPipeLabel(chars, from: cursor) {
                label = piped
                cursor = after
            }
            pending = scan
            pendingLabel = label.map(MermaidToken.decodeLabel)
        }
    }

    /// One or more node references joined by `&`.
    private static func parseGroup(
        _ chars: [Character], from start: Int, into builder: GraphBuilder
    ) -> ([DiagramGraph.NodeID], Int)? {
        var cursor = start
        var group: [DiagramGraph.NodeID] = []

        while true {
            while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
                cursor += 1
            }
            guard let (id, next) = parseNodeRef(chars, from: cursor, into: builder) else {
                return nil
            }
            group.append(id)
            cursor = next

            while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" {
                cursor += 1
            }
            guard cursor < chars.count, chars[cursor] == "&" else { return (group, cursor) }
            cursor += 1
        }
    }

    /// `id`, `id[Label]`, `id:::class`, `id:::class[Label]`, `id[Label]:::class`.
    private static func parseNodeRef(
        _ chars: [Character], from start: Int, into builder: GraphBuilder
    ) -> (DiagramGraph.NodeID, Int)? {
        guard let (raw, afterID) = MermaidToken.scanIdentifier(chars, from: start) else {
            return nil
        }
        var cursor = afterID
        var classes: [String] = []
        var shape: DiagramGraph.Shape?
        var label: DiagramGraph.Label?

        for _ in 0..<2 {
            if let (names, after) = scanClassMarker(chars, from: cursor) {
                classes.append(contentsOf: names)
                cursor = after
            }
            if shape == nil, let scan = MermaidToken.scanBracketed(chars, from: cursor) {
                shape = scan.shape
                label = MermaidToken.decodeLabel(scan.body)
                cursor = scan.end
            }
        }

        let id = DiagramGraph.NodeID(raw)
        for name in classes { builder.declareClass(name) }
        guard builder.mention(id, shape: shape, label: label, classes: classes) else { return nil }
        return (id, cursor)
    }

    private static func scanClassMarker(
        _ chars: [Character], from start: Int
    ) -> ([String], Int)? {
        guard start + 2 < chars.count,
              chars[start] == ":", chars[start + 1] == ":", chars[start + 2] == ":" else {
            return nil
        }
        var cursor = start + 3
        var text = ""
        while cursor < chars.count {
            let c = chars[cursor]
            if c.isWhitespace || c == "&" { break }
            if MermaidToken.scanBracketed(chars, from: cursor) != nil { break }
            if MermaidToken.scanEdge(chars, from: cursor) != nil { break }
            text.append(c)
            cursor += 1
        }
        guard !text.isEmpty else { return nil }
        return (text.split(separator: ",").map(String.init), cursor)
    }
}
