import Foundation

/// The structural result of reading a Mermaid source block: what points at what, with which
/// labels and shapes. Deliberately free of fonts, sizes and colors — a `DiagramGraph` is a pure
/// function of the source string, which is what lets the drawable/not decision be made once, by
/// the builder, before any width is known.
///
/// Every collection here is an **array in declaration order**. Dictionaries appear in the layout
/// only as `[NodeID: Int]` index maps and are never iterated. That is the root of the determinism
/// the `--render-txt` dumps depend on.
public struct DiagramGraph: Equatable {

    public enum Kind: Equatable {
        case flowchart
        case state
    }

    /// Ranks always grow in this direction. Layout works in one canonical space and applies the
    /// direction as a single transform at the end.
    public enum Direction: Equatable {
        case topDown, bottomUp, leftRight, rightLeft

        /// The token an author would have written, for the card header and the dump.
        public var token: String {
            switch self {
            case .topDown: return "TD"
            case .bottomUp: return "BT"
            case .leftRight: return "LR"
            case .rightLeft: return "RL"
            }
        }

        /// Ranks run along the vertical axis. The one thing the layout needs to know.
        public var isVertical: Bool {
            self == .topDown || self == .bottomUp
        }

        /// The direction 90° from this one, used when a wide diagram will not fit the column.
        public var perpendicular: Direction {
            switch self {
            case .topDown: return .leftRight
            case .leftRight: return .topDown
            case .bottomUp: return .rightLeft
            case .rightLeft: return .bottomUp
            }
        }

        public static func parse(_ token: String) -> Direction? {
            switch token.uppercased() {
            case "TD", "TB", "V": return .topDown
            case "BT": return .bottomUp
            case "LR": return .leftRight
            case "RL": return .rightLeft
            default: return nil
            }
        }
    }

    public struct NodeID: Hashable, Comparable {
        public let raw: String
        public init(_ raw: String) { self.raw = raw }
        public static func < (a: NodeID, b: NodeID) -> Bool { a.raw < b.raw }
    }

    /// A node or edge label, already split on the author's hard breaks. Automatic wrapping
    /// happens later, per line, during measurement.
    public struct Label: Equatable {
        public let lines: [String]
        public init(lines: [String]) { self.lines = lines }
        public var isEmpty: Bool { lines.allSatisfy { $0.isEmpty } }
        /// One-line form, for accessibility and the clipboard.
        public var flattened: String { lines.joined(separator: " ") }
    }

    public enum Shape: Equatable {
        case rect, rounded, stadium, subroutine, cylinder, circle, doubleCircle
        case diamond, hexagon, asymmetric
        case parallelogram, parallelogramAlt, trapezoid, trapezoidAlt
        case stateStart, stateEnd, forkJoin, choice, note

        /// Shapes whose geometry is defined by a single radius, so measurement squares the box.
        public var isRound: Bool {
            self == .circle || self == .doubleCircle || self == .stateStart || self == .stateEnd
        }

        /// Pseudo-states carry no label and have a fixed size.
        public var isMarker: Bool {
            self == .stateStart || self == .stateEnd || self == .forkJoin
        }
    }

    public enum Stroke: Equatable {
        case solid, dotted, thick, invisible
    }

    public enum Cap: Equatable {
        case none, arrow, circle, cross
    }

    public struct Node: Equatable {
        public let id: NodeID
        public let label: Label
        public let shape: Shape
        /// Class names from `classDef`/`class`/`:::`. The declared CSS is discarded — see
        /// `MermaidFlowchartParser` — but the *fact* of a class drives a theme-derived tint.
        public let classes: [String]
        /// Index into `clusters`, or nil for a top-level node.
        public let cluster: Int?
        /// Declaration order. The last resort of every tie-break in the layout.
        public let order: Int
    }

    public struct Edge: Equatable {
        public let from: NodeID
        public let to: NodeID
        public let label: Label?
        public let stroke: Stroke
        public let head: Cap
        public let tail: Cap
        /// How many ranks this edge must span, from the author's dash count. 1…8.
        public let minRankSpan: Int
        public let order: Int
    }

    public struct Cluster: Equatable {
        public let id: String
        public let title: Label?
        public let parent: Int?
        /// Direct members only; a nested cluster's members are not repeated here.
        public let members: [NodeID]
        public let order: Int
    }

    public let kind: Kind
    public let direction: Direction
    public let nodes: [Node]
    public let edges: [Edge]
    public let clusters: [Cluster]
    /// Class names in declaration order. One class in the whole diagram means the accent tint is
    /// unambiguous; several means each gets its own hashed slot.
    public let classNames: [String]

    public init(kind: Kind, direction: Direction, nodes: [Node], edges: [Edge],
                clusters: [Cluster], classNames: [String]) {
        self.kind = kind
        self.direction = direction
        self.nodes = nodes
        self.edges = edges
        self.clusters = clusters
        self.classNames = classNames
    }

    /// A node's position in `nodes`, for the layout's index maps.
    public func indexMap() -> [NodeID: Int] {
        var map: [NodeID: Int] = [:]
        for (index, node) in nodes.enumerated() { map[node.id] = index }
        return map
    }

    // MARK: Descriptions

    /// What the card header says once the diagram is drawn. Reports the **resolved** kind, so
    /// `graph TD` and `flowchart TD` both read `flowchart TD` — the honest statement of what was
    /// drawn rather than of what was typed.
    public var displayLabel: String {
        switch kind {
        case .flowchart: return "flowchart \(direction.token)"
        case .state: return "state diagram"
        }
    }

    /// Deterministic, width-independent, diff-friendly: integers and discrete tokens only, never
    /// coordinates. `make dump` is the primary regression check and must not move with layout.
    public var dumpDescription: String {
        let nodeWord = kind == .state ? "states" : "nodes"
        let edgeWord = kind == .state ? "transitions" : "edges"
        var parts = ["\(displayLabel), \(nodes.count) \(nodeWord), \(edges.count) \(edgeWord)"]
        if !clusters.isEmpty { parts.append("\(clusters.count) groups") }
        return parts.joined(separator: ", ")
    }

    /// Spoken in **source order**, never layout order: a VoiceOver label that reshuffled when a
    /// crossing-reduction sweep changed its mind would be useless to navigate by.
    ///
    /// Capped, because an uncapped enumeration of a hundred edges is not a label anyone can
    /// listen to.
    public var accessibilityDescription: String {
        let maxEdges = 40
        let heading = kind == .state
            ? "State diagram, \(nodes.count) states, \(edges.count) transitions."
            : "Flowchart, \(nodes.count) nodes, \(edges.count) connections."

        var index: [NodeID: Node] = [:]
        for node in nodes { index[node.id] = node }

        func name(_ id: NodeID) -> String {
            guard let node = index[id] else { return id.raw }
            switch node.shape {
            case .stateStart: return "start"
            case .stateEnd: return "end"
            default: break
            }
            let text = node.label.flattened
            return text.isEmpty ? id.raw : text
        }

        var sentences: [String] = []
        for edge in edges.prefix(maxEdges) {
            let verb = kind == .state ? "to" : "leads to"
            if let label = edge.label, !label.isEmpty {
                sentences.append("\(name(edge.from)) \(verb) \(name(edge.to)) on \(label.flattened).")
            } else {
                sentences.append("\(name(edge.from)) \(verb) \(name(edge.to)).")
            }
        }
        if edges.count > maxEdges {
            sentences.append("And \(edges.count - maxEdges) more.")
        }
        return ([heading] + sentences).joined(separator: " ")
    }
}

/// Ceilings that keep a pathological input from becoming a pathological layout.
///
/// Checked in `DiagramParser.parse`, i.e. **before** any layout runs, so a runaway diagram costs
/// parse time and nothing more. A graph this large is unreadable in a reading column anyway; the
/// reader gets the source card, which is honest.
public enum DiagramBudget {
    public static let maxNodes = 300
    public static let maxEdges = 600
    public static let maxSourceLines = 2000
    public static let maxClusterDepth = 4
}

/// The front door. Width-independent by construction: `nil` means "Folio does not draw this",
/// and that answer must never depend on how wide the column happens to be.
public enum DiagramParser {

    public static func parse(_ source: String) -> DiagramGraph? {
        let statements = MermaidToken.statements(in: source)
        guard statements.count <= DiagramBudget.maxSourceLines,
              let header = statements.first else { return nil }

        let words = header.text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let keyword = words.first else { return nil }
        let rest = words.dropFirst().map(String.init)
        let body = Array(statements.dropFirst())

        let graph: DiagramGraph?
        switch keyword.lowercased() {
        case "flowchart", "graph":
            let direction = rest.first.flatMap(DiagramGraph.Direction.parse) ?? .topDown
            // A trailing token that is not a direction is not a flowchart header we understand.
            if let first = rest.first, DiagramGraph.Direction.parse(first) == nil { return nil }
            graph = MermaidFlowchartParser.parse(body, direction: direction)
        case "statediagram-v2", "statediagram":
            guard rest.isEmpty else { return nil }
            graph = MermaidStateParser.parse(body)
        default:
            return nil
        }

        guard let graph, !graph.nodes.isEmpty,
              graph.nodes.count <= DiagramBudget.maxNodes,
              graph.edges.count <= DiagramBudget.maxEdges else { return nil }
        return graph
    }

    /// The kind the author declared, whether or not we draw it. Used by the source card's label
    /// so an undrawn diagram says what it is instead of pretending to be generic.
    public static func declaredKeyword(_ source: String) -> String? {
        source
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("%%") }
            .map { $0.components(separatedBy: CharacterSet(charactersIn: " \t")).first ?? $0 }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
