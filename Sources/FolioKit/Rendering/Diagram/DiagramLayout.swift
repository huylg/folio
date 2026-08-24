import AppKit

/// A diagram resolved to final coordinates for one available width, and the drawing of it.
///
/// Geometry and painting live together deliberately: the view that hosts a diagram holds no
/// geometry of its own, so the only way to obtain any is to ask for a `LaidOutDiagram`. That is
/// what makes "the height we measured is the height we drew" structural rather than a convention
/// somebody has to remember.
public struct LaidOutDiagram {

    struct Placed {
        let graphIndex: Int
        let frame: NSRect
    }

    struct PlacedCluster {
        let graphIndex: Int
        let frame: NSRect
    }

    public let graph: DiagramGraph
    /// The direction actually used, which is not the author's when a wide diagram was rotated to
    /// fit the column.
    public let direction: DiagramGraph.Direction
    public let wasFlipped: Bool
    /// Uniform scale applied at draw time. Never above 1: blowing a two-node diagram up to column
    /// width makes its type outgrow the prose beside it.
    public let scale: CGFloat
    /// Content size at `scale`, including the canvas padding. Excludes all card chrome.
    public let size: NSSize

    let naturalSize: NSSize
    let nodes: [Placed]
    let edges: [DiagramRouter.Routed]
    let clusters: [PlacedCluster]
    let metrics: DiagramMetrics

    /// What the card header says. Reports the resolved kind, and admits a rotation rather than
    /// silently contradicting the author's `LR`.
    public var headerLabel: String {
        guard wasFlipped else { return graph.displayLabel }
        let orientation = direction.isVertical ? "top-down" : "left-to-right"
        return "\(graph.displayLabel) — shown \(orientation) to fit"
    }
}

/// The layout entry point: parse result plus a width in, drawable geometry out.
///
/// Total by construction — anything that parsed gets drawn, scaled down as far as it takes.
/// There is deliberately no width-dependent "too small, show the source instead" tier: that would
/// be a second fallback reachable only at some widths, and `DiagramBudget` already rejects the
/// pathological inputs at parse time, where the answer cannot depend on the column.
public enum DiagramLayout {

    /// Below this, a rotation is worth trying. Above it the author's direction is already close
    /// enough to full size that reinterpreting their intent would not repay the surprise.
    static let flipThreshold: CGFloat = 0.75

    public static func layout(
        graph: DiagramGraph,
        width: CGFloat,
        metrics documentMetrics: DocumentMetrics
    ) -> LaidOutDiagram {
        let metrics = DiagramMetrics(document: documentMetrics)
        let available = max(1, width)

        let authored = resolve(graph, direction: graph.direction, metrics: metrics,
                               available: available, flipped: false)
        guard authored.scale < flipThreshold else { return authored }

        // A flowchart authored for a 1200pt browser window is short and very wide; rotated, it is
        // exactly the shape a reading column wants. Ties go to the author.
        let rotated = resolve(graph, direction: graph.direction.perpendicular, metrics: metrics,
                              available: available, flipped: true)
        return rotated.scale > authored.scale ? rotated : authored
    }

    private static func resolve(
        _ graph: DiagramGraph,
        direction: DiagramGraph.Direction,
        metrics: DiagramMetrics,
        available: CGFloat,
        flipped: Bool
    ) -> LaidOutDiagram {
        let result = LayeredLayout.layout(graph, direction: direction, metrics: metrics)
        let padding = metrics.canvasPadding
        let transform = Transform(direction: direction, canonical: result.size, padding: padding)
        let natural = transform.canvas

        var geometry: [DiagramRouter.NodeGeometry] = []
        var placed: [LaidOutDiagram.Placed] = []
        geometry.reserveCapacity(result.nodes.count)

        for node in result.nodes {
            let centre = transform.point(NSPoint(x: node.x, y: node.y))
            guard let graphIndex = node.graphIndex else {
                geometry.append(.init(centre: centre, frame: nil, shape: nil))
                continue
            }
            let box = transform.boxSize(across: node.boxAcross, along: node.boxAlong)
            let frame = NSRect(x: centre.x - box.width / 2, y: centre.y - box.height / 2,
                               width: box.width, height: box.height)
            geometry.append(.init(centre: centre, frame: frame,
                                  shape: graph.nodes[graphIndex].shape))
            placed.append(.init(graphIndex: graphIndex, frame: frame))
        }

        var labelCentres: [Int: NSPoint] = [:]
        for edge in result.edges {
            guard let centre = edge.labelCentre else { continue }
            labelCentres[edge.graphIndex] = transform.point(centre)
        }

        let routed = DiagramRouter.route(edges: result.edges, geometry: geometry,
                                         labelCentres: labelCentres, direction: direction,
                                         metrics: metrics)
        let clusters = result.clusters
            .filter(\.isDrawable)
            .map { LaidOutDiagram.PlacedCluster(graphIndex: $0.graphIndex,
                                                frame: transform.rect($0.frame)) }

        let scale = min(1, natural.width > 0 ? available / natural.width : 1)
        let size = NSSize(width: (natural.width * scale).rounded(.up),
                          height: (natural.height * scale).rounded(.up))

        return LaidOutDiagram(graph: graph, direction: direction, wasFlipped: flipped,
                              scale: scale, size: size, naturalSize: natural,
                              nodes: placed, edges: routed, clusters: clusters, metrics: metrics)
    }

    /// Canonical space to screen space. Rank runs downward and order rightward in canonical
    /// coordinates; each direction is one reflection, one axis swap, or both.
    struct Transform {
        let direction: DiagramGraph.Direction
        let canonical: CGSize
        let padding: CGFloat

        var canvas: NSSize {
            direction.isVertical
                ? NSSize(width: canonical.width + padding * 2,
                         height: canonical.height + padding * 2)
                : NSSize(width: canonical.height + padding * 2,
                         height: canonical.width + padding * 2)
        }

        func point(_ p: CGPoint) -> NSPoint {
            let mapped: NSPoint
            switch direction {
            case .topDown: mapped = NSPoint(x: p.x, y: p.y)
            case .bottomUp: mapped = NSPoint(x: p.x, y: canonical.height - p.y)
            case .leftRight: mapped = NSPoint(x: p.y, y: p.x)
            case .rightLeft: mapped = NSPoint(x: canonical.height - p.y, y: p.x)
            }
            return NSPoint(x: mapped.x + padding, y: mapped.y + padding)
        }

        func boxSize(across: CGFloat, along: CGFloat) -> NSSize {
            direction.isVertical
                ? NSSize(width: across, height: along)
                : NSSize(width: along, height: across)
        }

        /// A canonical rect, whose x axis is "across" and y axis is "along".
        func rect(_ r: CGRect) -> NSRect {
            let corners = [
                point(CGPoint(x: r.minX, y: r.minY)),
                point(CGPoint(x: r.maxX, y: r.maxY)),
            ]
            let minX = min(corners[0].x, corners[1].x)
            let minY = min(corners[0].y, corners[1].y)
            return NSRect(x: minX, y: minY,
                          width: abs(corners[1].x - corners[0].x),
                          height: abs(corners[1].y - corners[0].y))
        }
    }
}

// MARK: - Drawing

extension LaidOutDiagram {

    /// Paints the diagram into `rect`, which is the card's body area.
    ///
    /// Draw order matters for overlap: cluster boxes, then edges, then chips, then nodes. Nodes
    /// last, so an edge whose trimmed endpoint lands a hair inside a shape is hidden by it rather
    /// than showing as a spur.
    public func draw(in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        // Centre a diagram narrower than its column: at scale 1 a small graph pinned left reads
        // as a mistake rather than as a small graph.
        let inset = max(0, (rect.width - size.width) / 2)
        context.cgContext.translateBy(x: rect.minX + inset, y: rect.minY)
        context.cgContext.scaleBy(x: scale, y: scale)

        drawClusters()
        drawEdges()
        drawNodes()

        context.restoreGraphicsState()
    }

    // MARK: Clusters

    private func drawClusters() {
        for cluster in clusters {
            let spec = graph.clusters[cluster.graphIndex]
            let path = NSBezierPath(roundedRect: cluster.frame, xRadius: 8, yRadius: 8)
            Ink.tableStripe.setFill()
            path.fill()
            Ink.hairline.setStroke()
            path.lineWidth = metrics.nodeBorderWidth
            path.setLineDash(metrics.dashPattern, count: 2, phase: 0)
            path.stroke()

            guard let title = spec.title, !title.isEmpty else { continue }
            let attributes = metrics.clusterTitleAttributes()
            let text = metrics.attributed(title, attributes: attributes)
            let box = NSRect(x: cluster.frame.minX + metrics.clusterPadding / 2,
                             y: cluster.frame.minY + 3,
                             width: max(1, cluster.frame.width - metrics.clusterPadding),
                             height: metrics.clusterTitleHeight)
            text.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    // MARK: Edges

    private func drawEdges() {
        for routed in edges {
            let spec = graph.edges[routed.graphIndex]
            guard spec.stroke != .invisible, routed.points.count >= 2 else { continue }

            var points = routed.points
            var headAngle: CGFloat = 0
            var tailAngle: CGFloat = 0
            if spec.head != .none {
                (points, headAngle) = DiagramRouter.shortened(points, by: capInset(spec.head))
            }
            if spec.tail != .none {
                (points, tailAngle) = DiagramRouter.shortenedFromStart(
                    points, by: capInset(spec.tail))
            }

            let path = DiagramShapePath.roundedPolyline(points, radius: metrics.edgeCornerRadius)
            path.lineWidth = spec.stroke == .thick
                ? metrics.thickEdgeLineWidth
                : metrics.edgeLineWidth
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            if spec.stroke == .dotted { path.setLineDash(metrics.dashPattern, count: 2, phase: 0) }
            Ink.diagramEdge.setStroke()
            path.stroke()

            if spec.head != .none, let tip = routed.points.last {
                drawCap(spec.head, at: tip, angle: headAngle)
            }
            if spec.tail != .none, let tip = routed.points.first {
                drawCap(spec.tail, at: tip, angle: tailAngle)
            }
            if let frame = routed.labelFrame, let label = spec.label { drawChip(label, in: frame) }
        }
    }

    private func capInset(_ cap: DiagramGraph.Cap) -> CGFloat {
        switch cap {
        case .none: return 0
        case .arrow: return metrics.arrowLength - 1
        case .circle: return metrics.capCircleRadius * 2
        case .cross: return metrics.capCrossArm * 2
        }
    }

    private func drawCap(_ cap: DiagramGraph.Cap, at tip: NSPoint, angle: CGFloat) {
        Ink.diagramEdge.setFill()
        Ink.diagramEdge.setStroke()
        switch cap {
        case .none:
            return
        case .arrow:
            DiagramShapePath.arrowhead(at: tip, angle: angle,
                                       length: metrics.arrowLength,
                                       width: metrics.arrowWidth).fill()
        case .circle:
            let r = metrics.capCircleRadius
            let centre = NSPoint(x: tip.x - cos(angle) * r, y: tip.y - sin(angle) * r)
            NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r,
                                        width: r * 2, height: r * 2)).fill()
        case .cross:
            let path = DiagramShapePath.crossCap(at: tip, angle: angle, arm: metrics.capCrossArm)
            path.lineWidth = metrics.edgeLineWidth
            path.stroke()
        }
    }

    /// The chip knocks out the line behind it rather than carrying a border: two lines of code,
    /// and the result reads as a label on the edge instead of a box beside it.
    private func drawChip(_ label: DiagramGraph.Label, in frame: NSRect) {
        Ink.diagramBackground.setFill()
        frame.fill()
        let attributes = metrics.edgeLabelAttributes()
        metrics.attributed(label, attributes: attributes).draw(
            with: frame.insetBy(dx: metrics.labelChipPadding.width,
                                dy: metrics.labelChipPadding.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    // MARK: Nodes

    private func drawNodes() {
        for placed in nodes {
            let node = graph.nodes[placed.graphIndex]
            let frame = placed.frame
            let path = DiagramShapePath.path(for: node.shape, in: frame)

            let palette = fill(for: node)
            palette.fill.setFill()
            path.fill()

            if node.shape == .stateStart {
                // A filled dot: the outline would only fight the fill at this size.
                Ink.diagramEdge.setFill()
                path.fill()
            } else if node.shape == .stateEnd {
                Ink.diagramEdge.setStroke()
                path.lineWidth = metrics.nodeBorderWidth
                path.stroke()
                Ink.diagramEdge.setFill()
                DiagramShapePath.stateEndCore(in: frame).fill()
            } else if node.shape == .forkJoin {
                Ink.diagramEdge.setFill()
                path.fill()
            } else {
                Ink.diagramStroke.setStroke()
                path.lineWidth = metrics.nodeBorderWidth
                if node.shape == .note {
                    path.setLineDash(metrics.dashPattern, count: 2, phase: 0)
                }
                path.stroke()
                if let detail = DiagramShapePath.detail(for: node.shape, in: frame) {
                    detail.lineWidth = metrics.nodeBorderWidth
                    detail.stroke()
                }
            }

            guard !node.shape.isMarker, !node.label.isEmpty else { continue }
            var attributes = metrics.nodeLabelAttributes()
            attributes[.foregroundColor] = palette.text
            let text = metrics.attributed(node.label, attributes: attributes)
            let measured = metrics.textSize(node.label, attributes: attributes,
                                            wrappingAt: max(1, frame.width - 4))
            let box = NSRect(x: frame.minX + 2,
                             y: frame.midY - measured.height / 2,
                             width: max(1, frame.width - 4),
                             height: measured.height)
            text.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    /// A node's declared CSS is discarded; what survives is the *fact* of a class. One class in
    /// the diagram means the accent tint is unambiguous, so it gets `Ink.tintFill`. Several means
    /// each needs telling apart, so each goes through the tag palette's hash — the same class is
    /// then the same color everywhere, and both stay appearance-adaptive.
    private func fill(for node: DiagramGraph.Node) -> (fill: NSColor, text: NSColor) {
        guard let name = node.classes.first else { return (Ink.cardFillStrong, Ink.body) }
        if graph.classNames.count <= 1 { return (Ink.tintFill, Ink.body) }
        return TagPalette.pill(for: name)
    }
}
