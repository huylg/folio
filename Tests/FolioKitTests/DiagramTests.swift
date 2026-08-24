import AppKit
import XCTest
@testable import FolioKit

private func diagramFixture() throws -> MarkdownDocument {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("diagrams.md")
    return try MarkdownDocument(url: url)
}

private let diagramMetrics = DocumentMetrics(
    ramp: TypeRamp(family: .serif, textSize: 13),
    lineWidth: .comfortable, density: .airy
)

// MARK: - Parsing

/// What the whitelist accepts, and — just as load-bearing — what it refuses.
final class MermaidParserTests: XCTestCase {

    func testGraphAndFlowchartKeywordsResolveToTheSameKind() {
        let a = DiagramParser.parse("graph TD\n A --> B")
        let b = DiagramParser.parse("flowchart TD\n A --> B")
        XCTAssertEqual(a?.kind, .flowchart)
        XCTAssertEqual(a?.direction, .topDown)
        XCTAssertEqual(a?.displayLabel, b?.displayLabel)
        XCTAssertEqual(a?.displayLabel, "flowchart TD")
    }

    func testBareHeaderDefaultsToTopDown() {
        XCTAssertEqual(DiagramParser.parse("flowchart\n A --> B")?.direction, .topDown)
    }

    /// The label is the bracket's contents; the id is plumbing and must never be shown.
    func testNodeShapesAndLabelsParse() throws {
        let source = """
        flowchart LR
            a[Square] --> b(Round)
            b --> c{Diamond}
            c --> d((Circle))
            d --> e([Stadium])
            e --> f[[Sub]]
            f --> g[(Store)]
            g --> h{{Hex}}
            h --> i[/Skew/]
        """
        let graph = try XCTUnwrap(DiagramParser.parse(source))
        let shapes = graph.nodes.map(\.shape)
        XCTAssertEqual(shapes, [.rect, .rounded, .diamond, .circle, .stadium,
                                .subroutine, .cylinder, .hexagon, .parallelogram])
        XCTAssertEqual(graph.nodes.map { $0.label.flattened },
                       ["Square", "Round", "Diamond", "Circle", "Stadium",
                        "Sub", "Store", "Hex", "Skew"])
    }

    /// The spelling table. Every one of these appears in real documents, and the scanner's whole
    /// job is to be total over them.
    func testEdgeSpellingsParse() throws {
        let cases: [(String, DiagramGraph.Stroke, DiagramGraph.Cap, DiagramGraph.Cap)] = [
            ("-->", .solid, .arrow, .none),
            ("---", .solid, .none, .none),
            ("----", .solid, .none, .none),
            ("-.->", .dotted, .arrow, .none),
            ("-.-", .dotted, .none, .none),
            ("==>", .thick, .arrow, .none),
            ("===", .thick, .none, .none),
            ("--o", .solid, .circle, .none),
            ("--x", .solid, .cross, .none),
            ("<-->", .solid, .arrow, .arrow),
            ("o--o", .solid, .circle, .circle),
            ("x--x", .solid, .cross, .cross),
            ("~~~", .invisible, .none, .none),
        ]
        for (token, stroke, head, tail) in cases {
            let graph = try XCTUnwrap(DiagramParser.parse("flowchart LR\n A \(token) B"),
                                      "\(token) did not parse")
            let edge = try XCTUnwrap(graph.edges.first, "\(token) produced no edge")
            XCTAssertEqual(edge.stroke, stroke, "\(token) stroke")
            XCTAssertEqual(edge.head, head, "\(token) head")
            XCTAssertEqual(edge.tail, tail, "\(token) tail")
        }
    }

    func testEdgeLabelsParseInBothForms() throws {
        let piped = try XCTUnwrap(DiagramParser.parse("flowchart LR\n A -->|yes| B"))
        XCTAssertEqual(piped.edges.first?.label?.flattened, "yes")

        let middle = try XCTUnwrap(DiagramParser.parse("flowchart LR\n A -- warm --> B"))
        XCTAssertEqual(middle.edges.first?.label?.flattened, "warm")

        let dotted = try XCTUnwrap(DiagramParser.parse("flowchart LR\n A -. retry .-> B"))
        XCTAssertEqual(dotted.edges.first?.label?.flattened, "retry")
        XCTAssertEqual(dotted.edges.first?.stroke, .dotted)
    }

    /// A quoted label may contain what would otherwise be an edge token.
    func testAQuotedLabelDoesNotCloseItsOwnEdge() throws {
        let graph = try XCTUnwrap(DiagramParser.parse("flowchart LR\n A -->|\"a --> b\"| B"))
        XCTAssertEqual(graph.edges.first?.label?.flattened, "a --> b")
        XCTAssertEqual(graph.nodes.count, 2)
    }

    /// Longer links ask for more ranks. `-->` and `---` are both one; `--->` and `----` are two.
    func testDashCountCarriesRankSpan() throws {
        XCTAssertEqual(DiagramParser.parse("flowchart LR\n A --> B")?.edges.first?.minRankSpan, 1)
        XCTAssertEqual(DiagramParser.parse("flowchart LR\n A --- B")?.edges.first?.minRankSpan, 1)
        XCTAssertEqual(DiagramParser.parse("flowchart LR\n A ---> B")?.edges.first?.minRankSpan, 2)
        XCTAssertEqual(DiagramParser.parse("flowchart LR\n A ---- B")?.edges.first?.minRankSpan, 2)
    }

    /// `&` forms a product, which is what authors rely on for fan-in and fan-out.
    func testAmpersandGroupsFormAProduct() throws {
        let graph = try XCTUnwrap(DiagramParser.parse("flowchart LR\n A & B --> C & D"))
        XCTAssertEqual(graph.edges.count, 4)
        XCTAssertEqual(graph.nodes.count, 4)
    }

    func testChainsConnectEveryLink() throws {
        let graph = try XCTUnwrap(DiagramParser.parse("flowchart LR\n A --> B --> C"))
        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(graph.edges.map { "\($0.from.raw)\($0.to.raw)" }, ["AB", "BC"])
    }

    /// A later bare mention is a reference, not a redeclaration — chains re-mention ids
    /// constantly, and a bare `A` must not wipe out `A[Label]`.
    func testABareMentionDoesNotDowngradeADeclaredShape() throws {
        let graph = try XCTUnwrap(DiagramParser.parse("flowchart LR\n A(Round) --> B\n A --> C"))
        XCTAssertEqual(graph.nodes.first?.shape, .rounded)
        XCTAssertEqual(graph.nodes.first?.label.flattened, "Round")
    }

    func testSubgraphsBecomeClusters() throws {
        let source = """
        flowchart TD
            subgraph ingest [Ingest]
                A --> B
            end
            B --> C
        """
        let graph = try XCTUnwrap(DiagramParser.parse(source))
        XCTAssertEqual(graph.clusters.count, 1)
        XCTAssertEqual(graph.clusters.first?.title?.flattened, "Ingest")
        XCTAssertEqual(graph.clusters.first?.members.map(\.raw), ["A", "B"])
        // Never silently dropped: C is outside the group but still in the graph.
        XCTAssertEqual(graph.nodes.count, 3)
    }

    /// `:::` has to be parsed even though the declared CSS is thrown away, or the id itself is
    /// read wrong.
    func testClassMarkersDoNotCorruptTheNodeID() throws {
        let graph = try XCTUnwrap(
            DiagramParser.parse("flowchart LR\n A:::hot[Input] --> B\n classDef hot fill:#f96")
        )
        XCTAssertEqual(graph.nodes.first?.id.raw, "A")
        XCTAssertEqual(graph.nodes.first?.label.flattened, "Input")
        XCTAssertEqual(graph.nodes.first?.classes, ["hot"])
        XCTAssertEqual(graph.classNames, ["hot"])
    }

    func testCommentsAndDirectivesAreIgnored() throws {
        let source = """
        %%{init: {'theme':'dark'}}%%
        flowchart LR
            %% a comment
            A --> B   %% trailing

        """
        let graph = try XCTUnwrap(DiagramParser.parse(source))
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.edges.count, 1)
    }

    func testClickAndStyleAreSkippedRatherThanFatal() throws {
        let source = """
        flowchart LR
            A --> B
            click A "https://example.com"
            style A fill:#f9f
            linkStyle 0 stroke:#333
        """
        XCTAssertNotNil(DiagramParser.parse(source))
    }

    func testBreaksAndEntitiesDecodeInLabels() throws {
        let graph = try XCTUnwrap(
            DiagramParser.parse("flowchart LR\n A[\"one<br/>two #quot;q#quot;\"] --> B")
        )
        XCTAssertEqual(graph.nodes.first?.label.lines, ["one", "two \"q\""])
    }

    func testUnsupportedKindsReturnNil() {
        for keyword in ["sequenceDiagram", "classDiagram", "erDiagram", "gantt", "pie",
                        "journey", "mindmap", "gitGraph", "timeline", "quadrantChart"] {
            XCTAssertNil(DiagramParser.parse("\(keyword)\n  A --> B"),
                         "\(keyword) must not be drawn")
        }
    }

    /// Refusing is a supported outcome: the reader gets the source card, which is honest.
    func testGarbageReturnsNil() {
        XCTAssertNil(DiagramParser.parse(""))
        XCTAssertNil(DiagramParser.parse("%% only a comment"))
        XCTAssertNil(DiagramParser.parse("flowchart LR\n ]]] --> [[["))
        XCTAssertNil(DiagramParser.parse("flowchart LR\n A[unclosed --> B"))
        XCTAssertNil(DiagramParser.parse("flowchart SIDEWAYS\n A --> B"))
        XCTAssertNil(DiagramParser.parse("Just some prose that wandered into a fence."))
        XCTAssertNil(DiagramParser.parse("flowchart LR\n subgraph one\n A --> B"))
    }

    /// The ceiling is checked before any layout runs, so a runaway input costs parse time only.
    func testOversizedGraphsAreRejected() {
        let lines = (0...DiagramBudget.maxNodes).map { "n\($0) --> n\($0 + 1)" }
        XCTAssertNil(DiagramParser.parse((["flowchart TD"] + lines).joined(separator: "\n")))
    }

    func testDeclaredKeywordNamesWhatTheAuthorWrote() {
        XCTAssertEqual(DiagramParser.declaredKeyword("%% note\nsequenceDiagram\n A->>B: hi"),
                       "sequenceDiagram")
        XCTAssertEqual(BlockViewFactory.sourceLabel(for: "gantt\n title X"), "mermaid · gantt")
    }
}

// MARK: - State diagrams

final class MermaidStateTests: XCTestCase {

    private func machine() throws -> DiagramGraph {
        try XCTUnwrap(DiagramParser.parse("""
        stateDiagram-v2
            [*] --> Idle
            Idle --> Working : start
            Working --> Idle
            Working --> [*] : stop
        """))
    }

    func testStartAndEndAreOneNodeEach() throws {
        let graph = try machine()
        XCTAssertEqual(graph.kind, .state)
        XCTAssertEqual(graph.nodes.filter { $0.shape == .stateStart }.count, 1)
        XCTAssertEqual(graph.nodes.filter { $0.shape == .stateEnd }.count, 1)
        XCTAssertEqual(graph.nodes.count, 4)
        XCTAssertEqual(graph.edges.count, 4)
    }

    /// `[*] --> A` and `[*] --> B` fan out of a single dot: a state machine has one entry, and
    /// two dots would claim it had two.
    func testEveryStartArrowSharesOneDot() throws {
        let graph = try XCTUnwrap(DiagramParser.parse("""
        stateDiagram-v2
            [*] --> A
            [*] --> B
        """))
        XCTAssertEqual(graph.nodes.filter { $0.shape == .stateStart }.count, 1)
        XCTAssertEqual(graph.edges.count, 2)
    }

    func testTransitionLabelsAreRead() throws {
        let graph = try machine()
        XCTAssertEqual(graph.edges.compactMap { $0.label?.flattened }, ["start", "stop"])
    }

    /// `A --> B : label` and `Idle : waiting` share a prefix; the edge token is what tells them
    /// apart.
    func testDescriptionsAndLabelledTransitionsAreToldApart() throws {
        let graph = try XCTUnwrap(DiagramParser.parse("""
        stateDiagram-v2
            Idle : waiting for work
            Idle --> Busy : job
        """))
        XCTAssertEqual(graph.nodes.first?.label.flattened, "waiting for work")
        XCTAssertEqual(graph.edges.first?.label?.flattened, "job")
    }

    func testDescriptiveAliasAndModifiers() throws {
        let graph = try XCTUnwrap(DiagramParser.parse("""
        stateDiagram-v2
            state "Waiting for a batch" as idle
            state split <<fork>>
            idle --> split
        """))
        XCTAssertEqual(graph.nodes.first?.label.flattened, "Waiting for a batch")
        XCTAssertEqual(graph.nodes.last?.shape, .forkJoin)
    }

    /// Composite states reuse the cluster machinery. They are never flattened, because a
    /// flattened composite draws a structurally wrong picture.
    func testCompositeStatesBecomeClusters() throws {
        let graph = try XCTUnwrap(DiagramParser.parse("""
        stateDiagram-v2
            [*] --> Active
            state Active {
                Warm --> Hot
            }
        """))
        XCTAssertEqual(graph.clusters.count, 1)
        XCTAssertEqual(graph.clusters.first?.members.map(\.raw), ["Warm", "Hot"])
    }

    func testOnlyPlainArrowsAreLegalTransitions() {
        XCTAssertNil(DiagramParser.parse("stateDiagram-v2\n A -.-> B"))
        XCTAssertNil(DiagramParser.parse("stateDiagram-v2\n A ==> B"))
    }

    func testStateDumpUsesStateVocabulary() throws {
        XCTAssertEqual(try machine().dumpDescription, "state diagram, 4 states, 4 transitions")
    }
}

// MARK: - Layout

final class DiagramLayoutTests: XCTestCase {

    private func sources() -> [String] {
        [
            "flowchart LR\n A[Read] --> B[Parse] --> C[Render]",
            """
            flowchart TD
                Start[Start] --> Check{Cached?}
                Check -->|yes| Serve([Serve])
                Check -->|no| Fetch[[Fetch]]
                Fetch --> Store[(Store)]
                Store --> Serve
            """,
            """
            stateDiagram-v2
                [*] --> Idle
                Idle --> Working : start
                Working --> Idle
                Working --> [*] : stop
            """,
            """
            flowchart TD
                subgraph one [One]
                    A --> B
                end
                B --> C
                C --> A
            """,
            "flowchart LR\n A --> A\n A --> B\n A --> B",
        ]
    }

    private func laidOut(_ source: String, width: CGFloat = 480) -> LaidOutDiagram? {
        guard let graph = DiagramParser.parse(source) else { return nil }
        return DiagramLayout.layout(graph: graph, width: width, metrics: diagramMetrics)
    }

    func testNodesDoNotOverlap() throws {
        for source in sources() {
            for width in [320.0, 480.0, 900.0] as [CGFloat] {
                let laid = try XCTUnwrap(laidOut(source, width: width))
                let frames = laid.nodes.map(\.frame)
                for i in 0..<frames.count {
                    for j in (i + 1)..<frames.count {
                        let overlap = frames[i].insetBy(dx: 0.5, dy: 0.5)
                            .intersection(frames[j].insetBy(dx: 0.5, dy: 0.5))
                        XCTAssertTrue(overlap.isNull || overlap.isEmpty,
                                      "nodes \(i) and \(j) overlap at width \(width)")
                    }
                }
            }
        }
    }

    /// The invariant that catches a diagram drawing outside the height its card reserved.
    func testEveryNodeIsInsideTheCanvas() throws {
        for source in sources() {
            let laid = try XCTUnwrap(laidOut(source))
            let canvas = NSRect(origin: .zero, size: laid.naturalSize)
            for placed in laid.nodes {
                XCTAssertTrue(canvas.insetBy(dx: -0.5, dy: -0.5).contains(placed.frame),
                              "node \(placed.graphIndex) escapes the canvas")
            }
        }
    }

    /// The highest-value test in the file. Dictionary and set iteration order is the classic way
    /// a layout stops being reproducible, and `make dump` depends on this.
    func testLayoutIsDeterministic() throws {
        for source in sources() {
            let first = try XCTUnwrap(laidOut(source)).serialised
            for _ in 0..<9 {
                XCTAssertEqual(try XCTUnwrap(laidOut(source)).serialised, first)
            }
        }
    }

    func testEdgesTerminateOnTheirNodes() throws {
        let laid = try XCTUnwrap(laidOut(sources()[1]))
        var frames: [Int: NSRect] = [:]
        for placed in laid.nodes { frames[placed.graphIndex] = placed.frame }

        for routed in laid.edges {
            let spec = laid.graph.edges[routed.graphIndex]
            guard let fromIndex = laid.graph.nodes.firstIndex(where: { $0.id == spec.from }),
                  let toIndex = laid.graph.nodes.firstIndex(where: { $0.id == spec.to }),
                  let from = frames[fromIndex], let to = frames[toIndex],
                  let start = routed.points.first, let end = routed.points.last else {
                return XCTFail("edge \(routed.graphIndex) lost an endpoint")
            }
            XCTAssertTrue(from.insetBy(dx: -1.5, dy: -1.5).contains(start),
                          "edge \(routed.graphIndex) does not start on its source")
            XCTAssertTrue(to.insetBy(dx: -1.5, dy: -1.5).contains(end),
                          "edge \(routed.graphIndex) does not end on its target")
        }
    }

    /// Width is what a diagram trades height for. If this ever inverts, spread promotion stops
    /// paying for itself.
    func testAWiderCanvasIsNotTallerForALeftRightChart() throws {
        let source = "flowchart LR\n A[One] --> B[Two] --> C[Three] --> D[Four]"
        let narrow = try XCTUnwrap(laidOut(source, width: 420))
        let wide = try XCTUnwrap(laidOut(source, width: 900))
        XCTAssertLessThanOrEqual(wide.size.height, narrow.size.height)
    }

    /// The one place Folio reinterprets the author's intent, so it has to be both real and
    /// admitted in the header.
    func testAWideChartRotatesToFitANarrowColumnAndSaysSo() throws {
        let source = """
        flowchart LR
            A[Collect samples] --> B[Normalise inputs] --> C[Score candidates]
            C --> D[Select top-k] --> E[Emit batch]
        """
        let laid = try XCTUnwrap(laidOut(source, width: 420))
        XCTAssertTrue(laid.wasFlipped)
        XCTAssertEqual(laid.direction, .topDown)
        XCTAssertTrue(laid.headerLabel.contains("flowchart LR"))
        XCTAssertTrue(laid.headerLabel.contains("top-down"), laid.headerLabel)
    }

    func testAChartThatFitsKeepsTheAuthorsDirection() throws {
        let laid = try XCTUnwrap(laidOut("flowchart LR\n A --> B", width: 600))
        XCTAssertFalse(laid.wasFlipped)
        XCTAssertEqual(laid.direction, .leftRight)
        XCTAssertEqual(laid.headerLabel, "flowchart LR")
        XCTAssertEqual(laid.scale, 1)
    }

    /// Never scaled up: a two-node diagram blown out to column width outgrows the prose.
    func testASmallDiagramIsNotEnlarged() throws {
        let laid = try XCTUnwrap(laidOut("flowchart LR\n A --> B", width: 900))
        XCTAssertEqual(laid.scale, 1)
        XCTAssertLessThan(laid.size.width, 900)
    }

    /// A label has to sit inside the shape that was measured for it, slanted sides included.
    func testLabelsFitInsideSlantedShapes() throws {
        for (source, shape) in [("flowchart TD\n A{Is the cache warm enough?}", "diamond"),
                                ("flowchart TD\n A{{Is the cache warm enough?}}", "hexagon")] {
            let laid = try XCTUnwrap(laidOut(source, width: 900))
            let placed = try XCTUnwrap(laid.nodes.first)
            let node = laid.graph.nodes[placed.graphIndex]
            let path = DiagramShapePath.path(for: node.shape, in: placed.frame)
            let metrics = DiagramMetrics(document: diagramMetrics)
            let text = metrics.textSize(node.label, attributes: metrics.nodeLabelAttributes(),
                                        wrappingAt: max(1, placed.frame.width - 4))
            let box = NSRect(x: placed.frame.midX - text.width / 2,
                             y: placed.frame.midY - text.height / 2,
                             width: text.width, height: text.height)
            for corner in [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
                           NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY)] {
                XCTAssertTrue(path.contains(corner), "\(shape) label escapes at \(corner)")
            }
        }
    }
}

private extension LaidOutDiagram {
    /// Integer-rounded, so the comparison is about the layout rather than about float noise.
    var serialised: String {
        var lines: [String] = ["\(direction.token) \(Int(size.width))x\(Int(size.height))"]
        for placed in nodes {
            lines.append("n \(placed.graphIndex) \(Int(placed.frame.minX)) "
                         + "\(Int(placed.frame.minY)) \(Int(placed.frame.width)) "
                         + "\(Int(placed.frame.height))")
        }
        for routed in edges {
            let points = routed.points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
            lines.append("e \(routed.graphIndex) \(points)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The card

final class DiagramBlockViewTests: XCTestCase {

    private func graph() throws -> DiagramGraph {
        try XCTUnwrap(DiagramParser.parse("graph TD\n A[Read] --> B[Parse]"))
    }

    /// Mirrors `TableTests.testMeasuredHeightMatchesTheView`: the stack positions everything from
    /// the measured number, so a view that draws taller would move content under the reader.
    func testMeasuredHeightMatchesTheView() throws {
        let graph = try graph()
        for width in [320.0, 480.0, 760.0] as [CGFloat] {
            let view = DiagramBlockView(source: "graph TD\n A --> B", graph: graph,
                                        metrics: diagramMetrics, host: nil)
            let measured = BlockViewFactory.height(
                for: .diagram(source: "graph TD\n A --> B", graph: graph),
                width: width, metrics: diagramMetrics
            )
            XCTAssertEqual(view.sizeThatFits(width: width).height, measured, accuracy: 0.5)
        }
    }

    func testHeaderNamesTheResolvedKind() throws {
        let view = DiagramBlockView(source: "graph TD\n A --> B", graph: try graph(),
                                    metrics: diagramMetrics, host: nil)
        XCTAssertEqual(view.headerLabel.stringValue, "flowchart TD")
    }

    func testTheCardUsesTheDiagramSurface() throws {
        let view = DiagramBlockView(source: "graph TD\n A --> B", graph: try graph(),
                                    metrics: diagramMetrics, host: nil)
        XCTAssertEqual(view.cardFillColor, Ink.diagramBackground)
    }

    func testAnUndrawableDiagramFallsBackToASourceCard() {
        let source = "sequenceDiagram\n Alice->>Bob: Hello"
        let payload = BlockPayload.diagram(source: source, graph: nil)
        let view = BlockViewFactory.makeView(for: payload, host: nil)
        let card = view as? SourceCardView
        XCTAssertNotNil(card, "an undrawn diagram must stay a source card")
        XCTAssertEqual(card?.headerLabel.stringValue, "mermaid · sequenceDiagram")
        XCTAssertEqual(
            BlockViewFactory.height(for: payload, width: 480, metrics: diagramMetrics),
            SourceCardView.height(source: source, width: 480, metrics: diagramMetrics),
            accuracy: 0.5
        )
    }

    func testAccessibilityDescribesTheStructureInSourceOrder() throws {
        let view = DiagramBlockView(source: "graph TD\n A --> B", graph: try graph(),
                                    metrics: diagramMetrics, host: nil)
        XCTAssertEqual(view.accessibilityRole(), .group)
        let label = try XCTUnwrap(view.accessibilityLabel())
        XCTAssertTrue(label.hasPrefix("Flowchart, 2 nodes, 1 connections."), label)
        XCTAssertTrue(label.contains("Read leads to Parse."), label)
    }

    /// An uncapped enumeration of a hundred edges is not a label anyone can listen to.
    func testAccessibilityLabelIsCappedOnLargeGraphs() throws {
        let lines = (0..<60).map { "n\($0) --> n\($0 + 1)" }
        let graph = try XCTUnwrap(
            DiagramParser.parse((["flowchart TD"] + lines).joined(separator: "\n"))
        )
        XCTAssertTrue(graph.accessibilityDescription.contains("And 20 more."))
    }

    func testTheCopyButtonYieldsTheMermaidSource() throws {
        let host = RecordingHost(metrics: diagramMetrics)
        let source = "graph TD\n A[Read] --> B[Parse]"
        let view = DiagramBlockView(source: source, graph: try graph(),
                                    metrics: diagramMetrics, host: host)
        let button = try XCTUnwrap(
            view.headerAccessories.arrangedSubviews.first as? NSButton
        )
        _ = button.target?.perform(button.action, with: button)
        XCTAssertEqual(host.copied, [source])
    }

    /// Measuring and then drawing at the same width must cost one layout, not two.
    func testMeasureAndDrawShareOneLayout() throws {
        let host = RecordingHost(metrics: diagramMetrics)
        let source = "graph TD\n A[Read] --> B[Parse]"
        let payload = BlockPayload.diagram(source: source, graph: try graph())

        _ = BlockViewFactory.height(for: payload, width: 480,
                                    metrics: diagramMetrics, host: host)
        let view = BlockViewFactory.makeView(for: payload, host: host)
        _ = (view as? DiagramBlockView)?.sizeThatFits(width: 480)
        XCTAssertEqual(host.diagramLayouts.misses, 1)
    }

    func testTheCacheIsBoundedAndClearable() throws {
        let host = RecordingHost(metrics: diagramMetrics)
        let graph = try graph()
        for width in 300..<420 {
            _ = host.diagramLayouts.layout(source: "s", graph: graph,
                                           width: CGFloat(width), metrics: diagramMetrics)
        }
        host.diagramLayouts.removeAll()
        XCTAssertEqual(host.diagramLayouts.misses, 0)
    }
}

// MARK: - Document integration

final class DiagramDocumentTests: XCTestCase {

    private func build(_ document: MarkdownDocument,
                       settings: AppSettings? = nil) -> BuiltDocument {
        AttributedDocumentBuilder(document: document, metrics: diagramMetrics,
                                  settings: settings ?? .shared).build()
    }

    func testTheFixtureDrawsWhatItCanAndSaysWhatItCannot() throws {
        let built = build(try diagramFixture())
        let payloads = built.components.compactMap { component -> BlockPayload? in
            guard case .widget(let payload) = component.content else { return nil }
            return payload
        }
        let diagrams = payloads.compactMap { payload -> (String, DiagramGraph?)? in
            guard case .diagram(let source, let graph) = payload else { return nil }
            return (source, graph)
        }
        XCTAssertEqual(diagrams.count, 5)
        XCTAssertEqual(diagrams.map { $0.1?.dumpDescription },
                       ["flowchart LR, 3 nodes, 2 edges",
                        "flowchart TD, 5 nodes, 5 edges",
                        "state diagram, 4 states, 4 transitions",
                        nil,
                        nil])
    }

    /// The dump has to name an undrawn diagram explicitly, or a regression that stops drawing
    /// looks like unchanged output.
    func testTheDumpNamesBothOutcomes() throws {
        let dump = DocumentDump.dump(document: try diagramFixture())
        XCTAssertTrue(dump.contains("diagram flowchart LR, 3 nodes, 2 edges"), dump)
        XCTAssertTrue(dump.contains("diagram state diagram, 4 states, 4 transitions"), dump)
        XCTAssertTrue(dump.contains("diagram unsupported(sequenceDiagram)"), dump)
        XCTAssertTrue(dump.contains("diagram unsupported(flowchart)"), dump)
    }

    /// The counter reports what the author wrote, not what Folio drew — a stat that moved when a
    /// reader flipped a preference would make the meta line lie about the document.
    func testTheDiagramCountIsIndependentOfWhatWeCanDraw() throws {
        XCTAssertEqual(try diagramFixture().stats.diagrams, 5)
    }

    func testTurningDiagramsOffProducesACodeCard() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "folio.diagram.tests"))
        defaults.removePersistentDomain(forName: "folio.diagram.tests")
        let settings = AppSettings(defaults: defaults)
        settings.renderDiagrams = false
        defer { defaults.removePersistentDomain(forName: "folio.diagram.tests") }

        let built = build(try diagramFixture(), settings: settings)
        for component in built.components {
            if case .widget(let payload) = component.content, case .diagram = payload {
                XCTFail("a diagram widget survived the setting")
            }
        }
        let labels = built.components.compactMap { component -> String? in
            guard case .code(let label, _, _) = component.content else { return nil }
            return label
        }
        XCTAssertEqual(labels.filter { $0 == "mermaid" }.count, 5)
    }
}

// MARK: - The document stack

/// The diagram in the page, rather than in isolation: it has to reserve exactly the height it
/// draws into, and a tall one has to take the escape hatch the stack already offers.
final class DiagramStackTests: XCTestCase {

    private func pane(_ markdown: String, columns: Int) throws -> NativeDocumentView {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-diagram-\(UUID().uuidString).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let view = NativeDocumentView(metrics: diagramMetrics)
        view.frame = NSRect(x: 0, y: 0,
                            width: paneWidth(forColumns: columns, metrics: diagramMetrics),
                            height: 700)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try MarkdownDocument(url: url), metrics: diagramMetrics)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return view
    }

    private func diagramIndex(_ view: NativeDocumentView) throws -> Int {
        try XCTUnwrap(view.built?.components.firstIndex {
            if case .widget(.diagram) = $0.content { return true } else { return false }
        })
    }

    /// The height the stack reserved and the height the card occupies are the same number.
    func testTheCardFillsTheHeightTheStackReserved() throws {
        let view = try pane("""
        # Chart

        ```mermaid
        flowchart TD
            A[Read] --> B[Parse]
            B --> C[Render]
        ```
        """, columns: 1)

        let index = try diagramIndex(view)
        let card = try XCTUnwrap(
            view.stackView.subviews.compactMap { $0 as? DiagramBlockView }.first,
            "no diagram card was built"
        )
        XCTAssertEqual(card.frame.height, view.stackView.frame(ofComponent: index).height,
                       accuracy: 0.5)
        XCTAssertGreaterThan(card.frame.height, 60)
    }

    /// A diagram taller than a column takes the whole spread — and because a diagram trades
    /// height for width, the extra width usually makes it shorter as well. No new code path:
    /// this is the promotion the stack already applies to tables and images.
    func testATallDiagramSpansTheSpread() throws {
        var lines = ["# Tall", "", "```mermaid", "flowchart TD"]
        for index in 1...24 { lines.append("    n\(index)[Step \(index)] --> n\(index + 1)[Step \(index + 1)]") }
        lines += ["```", "", "After."]

        let view = try pane(lines.joined(separator: "\n"), columns: 2)
        let index = try diagramIndex(view)
        XCTAssertEqual(view.stackView.columnCount, 2)
        XCTAssertTrue(view.stackView.spans(component: index),
                      "a tall diagram did not take a page of its own")
    }
}
