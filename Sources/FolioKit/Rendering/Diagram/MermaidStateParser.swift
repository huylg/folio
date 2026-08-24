import Foundation

/// Reads the `stateDiagram-v2` dialect onto the same `DiagramGraph` the flowchart parser builds.
///
/// A state diagram is a directed graph with different shapes, so everything downstream —
/// ranking, ordering, routing, drawing — is shared. Only the surface syntax differs.
///
/// Two decisions worth stating, because both are visible to a reader:
///
/// - **`[*]` is one node per scope, not one per arrow.** `[*] --> A` and `[*] --> B` fan out of a
///   single dot, which is how a state machine is read. A separate dot per arrow would suggest two
///   entry points where the author meant one.
/// - **Composite states reuse the cluster machinery.** They are never flattened: a flattened
///   composite draws a structurally wrong picture, so if clusters cannot be drawn the diagram is
///   refused instead.
enum MermaidStateParser {

    static func parse(_ statements: [MermaidToken.Statement]) -> DiagramGraph? {
        let builder = GraphBuilder()
        var direction = DiagramGraph.Direction.topDown
        /// One start and one end marker per open scope, created on first use.
        var scopeStack: [Int] = []
        var scopeSerial = 0
        var collectingNote: Bool = false

        func scopeKey() -> String { scopeStack.last.map(String.init) ?? "root" }

        for statement in statements {
            let text = statement.text

            if collectingNote {
                if text.lowercased() == "end note" { collectingNote = false }
                continue
            }

            let first = text
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first
                .map { String($0).lowercased() } ?? ""

            switch first {
            case "}":
                guard text == "}", builder.closeCluster() else { return nil }
                scopeStack.removeLast()
                continue

            case "direction":
                let token = text.dropFirst("direction".count).trimmingCharacters(in: .whitespaces)
                guard let parsed = DiagramGraph.Direction.parse(token) else { return nil }
                if scopeStack.isEmpty { direction = parsed }
                continue

            case "note":
                guard handleNote(text, into: builder, collecting: &collectingNote) else {
                    return nil
                }
                continue

            case "classdef":
                let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2 else { return nil }
                for name in parts[1].split(separator: ",") {
                    builder.declareClass(String(name).trimmingCharacters(in: .whitespaces))
                }
                continue

            case "class":
                let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 3 else { return nil }
                let names = parts[2].split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                for name in names { builder.declareClass(name) }
                for raw in parts[1].split(separator: ",") {
                    let id = DiagramGraph.NodeID(String(raw).trimmingCharacters(in: .whitespaces))
                    guard builder.mention(id) else { return nil }
                    builder.addClasses(names, to: id)
                }
                continue

            case "state":
                scopeSerial += 1
                guard handleStateDeclaration(text, into: builder,
                                             scopeStack: &scopeStack,
                                             serial: scopeSerial) else { return nil }
                continue

            default:
                break
            }

            if text.hasPrefix("accTitle") || text.hasPrefix("accDescr") { continue }
            guard parseTransitionOrDescription(text, into: builder, scope: scopeKey()) else {
                return nil
            }
        }

        return builder.build(kind: .state, direction: direction)
    }

    // MARK: Declarations

    /// `state id`, `state "description" as id`, `state id <<fork>>`, `state id {`.
    private static func handleStateDeclaration(
        _ text: String,
        into builder: GraphBuilder,
        scopeStack: inout [Int],
        serial: Int
    ) -> Bool {
        var rest = String(text.dropFirst("state".count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return false }

        let opensComposite = rest.hasSuffix("{")
        if opensComposite {
            rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        // `state "long description" as id`
        if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
            let description = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let words = tail.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count == 2, words[0].lowercased() == "as" else { return false }
            let id = DiagramGraph.NodeID(String(words[1]))
            guard builder.mention(id, shape: .rounded,
                                  label: MermaidToken.decodeLabel(description)) else { return false }
            return opensComposite
                ? openComposite(id.raw, label: MermaidToken.decodeLabel(description),
                                into: builder, scopeStack: &scopeStack, serial: serial)
                : true
        }

        let words = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let raw = words.first else { return false }
        let id = DiagramGraph.NodeID(raw)

        if words.count == 2, words[1].hasPrefix("<<"), words[1].hasSuffix(">>") {
            let modifier = String(words[1].dropFirst(2).dropLast(2)).lowercased()
            let shape: DiagramGraph.Shape
            switch modifier {
            case "fork", "join": shape = .forkJoin
            case "choice": shape = .choice
            case "end": shape = .stateEnd
            default: return false
            }
            guard builder.mention(id, shape: shape, label: DiagramGraph.Label(lines: [""]))
            else { return false }
            builder.forceShape(id, shape)
            return !opensComposite
        }

        guard words.count == 1 else { return false }
        guard builder.mention(id, shape: .rounded,
                              label: MermaidToken.decodeLabel(raw)) else { return false }
        return opensComposite
            ? openComposite(raw, label: MermaidToken.decodeLabel(raw), into: builder,
                            scopeStack: &scopeStack, serial: serial)
            : true
    }

    /// A composite state becomes a cluster. The state's own node is *not* kept — its children
    /// stand in for it — so the cluster carries the title instead.
    private static func openComposite(
        _ id: String,
        label: DiagramGraph.Label,
        into builder: GraphBuilder,
        scopeStack: inout [Int],
        serial: Int
    ) -> Bool {
        guard builder.openCluster(id: id, title: label) else { return false }
        scopeStack.append(serial)
        return true
    }

    /// `note left of X : text`, or the block form terminated by `end note`.
    private static func handleNote(
        _ text: String, into builder: GraphBuilder, collecting: inout Bool
    ) -> Bool {
        // `note left of X` / `note right of X`, then either `: text` or a block.
        let anchorAndBody = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let header = anchorAndBody[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard header.count == 4, header[2].lowercased() == "of",
              ["left", "right"].contains(header[1].lowercased()) else { return false }

        let anchor = DiagramGraph.NodeID(String(header[3]))
        guard builder.mention(anchor) else { return false }

        guard anchorAndBody.count == 2 else {
            // Block form: the body arrives on following lines, and is not drawn in this pass.
            collecting = true
            return true
        }
        let body = String(anchorAndBody[1]).trimmingCharacters(in: .whitespaces)
        let noteID = DiagramGraph.NodeID("__note__\(anchor.raw)")
        guard builder.mention(noteID, shape: .note,
                              label: MermaidToken.decodeLabel(body)) else { return false }
        // A note hangs off its anchor rather than participating in the flow: dotted, capless, and
        // it is the only edge that does not carry a direction the reader should follow.
        return builder.connect(from: anchor, to: noteID, label: nil, stroke: .dotted,
                               head: .none, tail: .none, minRankSpan: 1)
    }

    // MARK: Transitions

    /// `A --> B`, `A --> B : label`, `[*] --> A`, `A --> [*]`, chained, or `id : description`.
    private static func parseTransitionOrDescription(
        _ text: String, into builder: GraphBuilder, scope: String
    ) -> Bool {
        let chars = Array(text)

        // The two forms are ambiguous by prefix, so look for an edge token first: `A --> B : x`
        // is a labelled transition, `Idle : waiting` is a description.
        var hasEdge = false
        var probe = 0
        while probe < chars.count {
            if MermaidToken.scanEdge(chars, from: probe) != nil { hasEdge = true; break }
            probe += 1
        }

        guard hasEdge else { return parseDescription(text, into: builder) }

        // A trailing `: label` belongs to the whole transition.
        var body = text
        var label: DiagramGraph.Label?
        if let colon = trailingColonIndex(chars) {
            label = MermaidToken.decodeLabel(String(chars[(colon + 1)...]))
            body = String(chars[0..<colon])
        }

        let line = Array(body)
        var cursor = 0
        var previous: DiagramGraph.NodeID?

        while true {
            while cursor < line.count, line[cursor] == " " || line[cursor] == "\t" { cursor += 1 }
            guard let (id, next) = parseStateRef(line, from: cursor, into: builder,
                                                 scope: scope,
                                                 isTarget: previous != nil) else { return false }
            cursor = next

            while cursor < line.count, line[cursor] == " " || line[cursor] == "\t" { cursor += 1 }
            if cursor >= line.count {
                guard let previous else { return true }
                return builder.connect(from: previous, to: id, label: label, stroke: .solid,
                                       head: .arrow, tail: .none, minRankSpan: 1)
            }

            guard let scan = MermaidToken.scanEdge(line, from: cursor),
                  scan.stroke == .solid, scan.head == .arrow, scan.tail == .none,
                  scan.inlineLabel == nil else { return false }
            if let previous {
                guard builder.connect(from: previous, to: id, label: nil, stroke: .solid,
                                      head: .arrow, tail: .none, minRankSpan: 1) else {
                    return false
                }
            }
            previous = id
            cursor = scan.end
        }
    }

    /// The `:` that introduces a transition label, ignoring `:::` class markers and quoted text.
    private static func trailingColonIndex(_ chars: [Character]) -> Int? {
        var inQuote = false
        var index = 0
        var found: Int?
        while index < chars.count {
            if chars[index] == "\"" { inQuote.toggle() }
            if !inQuote, chars[index] == ":" {
                if index + 1 < chars.count, chars[index + 1] == ":" {
                    index += 3
                    continue
                }
                found = index
            }
            index += 1
        }
        return found
    }

    /// `Idle : waiting for work` — a description attached to a state.
    private static func parseDescription(_ text: String, into builder: GraphBuilder) -> Bool {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            // A bare state name on its own line is a legal declaration.
            let raw = text.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty, !raw.contains(" ") else { return false }
            return builder.mention(DiagramGraph.NodeID(raw), shape: .rounded,
                                   label: MermaidToken.decodeLabel(raw))
        }
        let raw = String(parts[0]).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains(" ") else { return false }
        let id = DiagramGraph.NodeID(raw)
        guard builder.mention(id, shape: .rounded,
                              label: MermaidToken.decodeLabel(raw)) else { return false }
        builder.setLabel(id, MermaidToken.decodeLabel(String(parts[1])))
        return true
    }

    /// A state reference, with `[*]` resolved to the scope's shared start or end marker.
    private static func parseStateRef(
        _ chars: [Character], from start: Int, into builder: GraphBuilder,
        scope: String, isTarget: Bool
    ) -> (DiagramGraph.NodeID, Int)? {
        if start + 2 < chars.count,
           chars[start] == "[", chars[start + 1] == "*", chars[start + 2] == "]" {
            let id = DiagramGraph.NodeID(isTarget ? "__end__\(scope)" : "__start__\(scope)")
            let shape: DiagramGraph.Shape = isTarget ? .stateEnd : .stateStart
            guard builder.mention(id, shape: shape,
                                  label: DiagramGraph.Label(lines: [""])) else { return nil }
            builder.forceShape(id, shape)
            return (id, start + 3)
        }
        guard let (raw, after) = MermaidToken.scanIdentifier(chars, from: start) else { return nil }
        let id = DiagramGraph.NodeID(raw)
        guard builder.mention(id, shape: .rounded,
                              label: MermaidToken.decodeLabel(raw)) else { return nil }
        return (id, after)
    }
}
