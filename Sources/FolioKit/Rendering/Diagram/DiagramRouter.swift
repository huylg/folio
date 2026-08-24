import AppKit

/// Turns a laid-out edge into the polyline that will actually be stroked.
///
/// Runs in **final screen coordinates**, after the direction transform, so a boundary
/// intersection is computed against the rectangle the shape is really drawn in and an arrowhead
/// angle falls out of the geometry rather than being derived from the layout's canonical axes.
enum DiagramRouter {

    struct Routed {
        let graphIndex: Int
        /// Trimmed to the two node boundaries, with any bow or corner already in place.
        var points: [NSPoint]
        var labelFrame: NSRect?
    }

    /// What the router needs to know about the nodes an edge touches.
    struct NodeGeometry {
        let centre: NSPoint
        /// Nil for a virtual node, which has no boundary to trim against.
        let frame: NSRect?
        let shape: DiagramGraph.Shape?
    }

    static func route(
        edges: [LayeredLayout.Edge],
        geometry: [NodeGeometry],
        labelCentres: [Int: NSPoint],
        direction: DiagramGraph.Direction,
        metrics: DiagramMetrics
    ) -> [Routed] {
        edges.map { edge in
            var points: [NSPoint]
            if edge.isSelfLoop {
                points = selfLoop(around: edge, geometry: geometry,
                                  direction: direction, metrics: metrics)
            } else {
                points = polyline(for: edge, geometry: geometry, metrics: metrics)
            }

            var labelFrame: NSRect?
            if edge.labelSize != .zero {
                let centre = labelCentres[edge.graphIndex] ?? midpoint(of: points)
                labelFrame = NSRect(
                    x: centre.x - edge.labelSize.width / 2,
                    y: centre.y - edge.labelSize.height / 2,
                    width: edge.labelSize.width,
                    height: edge.labelSize.height
                )
            }
            return Routed(graphIndex: edge.graphIndex, points: points, labelFrame: labelFrame)
        }
    }

    // MARK: Ordinary edges

    private static func polyline(
        for edge: LayeredLayout.Edge,
        geometry: [NodeGeometry],
        metrics: DiagramMetrics
    ) -> [NSPoint] {
        var raw = edge.path.map { geometry[$0].centre }
        guard raw.count >= 2 else { return raw }

        // Parallel edges share both endpoints, so without a bow they would draw on top of each
        // other and read as one link.
        if raw.count == 2, edge.parallelCount > 1 {
            let offset = (CGFloat(edge.parallelIndex) - CGFloat(edge.parallelCount - 1) / 2)
                * metrics.parallelEdgeSpread
            if abs(offset) > 0.01 {
                let a = raw[0], b = raw[1]
                let length = DiagramShapePath.distance(a, b)
                if length > 0.01 {
                    let normal = NSPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
                    raw.insert(NSPoint(x: (a.x + b.x) / 2 + normal.x * offset,
                                       y: (a.y + b.y) / 2 + normal.y * offset), at: 1)
                }
            }
        }

        raw = dropCollinear(raw)

        // Trim to the boundaries of the shapes at each end. A virtual endpoint cannot happen —
        // the first and last entries of a chain are always real nodes.
        let head = geometry[edge.path[0]]
        let tail = geometry[edge.path[edge.path.count - 1]]
        if let frame = head.frame, let shape = head.shape, raw.count >= 2 {
            raw[0] = DiagramShapePath.boundary(of: shape, in: frame, toward: raw[1])
        }
        if let frame = tail.frame, let shape = tail.shape, raw.count >= 2 {
            raw[raw.count - 1] = DiagramShapePath.boundary(of: shape, in: frame,
                                                           toward: raw[raw.count - 2])
        }
        return raw
    }

    /// Removes interior points that lie on the straight line between their neighbours, so a
    /// chain of virtual nodes that happened to line up is stroked as one straight segment rather
    /// than as a run of segments with rounding artefacts at every joint.
    private static func dropCollinear(_ points: [NSPoint]) -> [NSPoint] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        for index in 1..<(points.count - 1) {
            let a = result[result.count - 1], b = points[index], c = points[index + 1]
            let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            let scale = max(1, DiagramShapePath.distance(a, c))
            if abs(cross) / scale > 1 { result.append(b) }
        }
        result.append(points[points.count - 1])
        return result
    }

    // MARK: Self loops

    /// A stub off the trailing side of the node — right when the flow runs vertically, bottom
    /// when it runs horizontally. The node reserved this room during layout, so the loop cannot
    /// collide with a neighbour.
    private static func selfLoop(
        around edge: LayeredLayout.Edge,
        geometry: [NodeGeometry],
        direction: DiagramGraph.Direction,
        metrics: DiagramMetrics
    ) -> [NSPoint] {
        guard let index = edge.path.first, let frame = geometry[index].frame else { return [] }
        let extent = metrics.selfLoopExtent

        if direction.isVertical {
            let top = frame.midY - frame.height / 4
            let bottom = frame.midY + frame.height / 4
            return [
                NSPoint(x: frame.maxX, y: top),
                NSPoint(x: frame.maxX + extent, y: top),
                NSPoint(x: frame.maxX + extent, y: bottom),
                NSPoint(x: frame.maxX, y: bottom),
            ]
        }
        let left = frame.midX - frame.width / 4
        let right = frame.midX + frame.width / 4
        return [
            NSPoint(x: left, y: frame.maxY),
            NSPoint(x: left, y: frame.maxY + extent),
            NSPoint(x: right, y: frame.maxY + extent),
            NSPoint(x: right, y: frame.maxY),
        ]
    }

    // MARK: Helpers

    private static func midpoint(of points: [NSPoint]) -> NSPoint {
        guard let first = points.first, let last = points.last else { return .zero }
        guard points.count > 2 else {
            return NSPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
        }
        return points[points.count / 2]
    }

    /// Pulls the final point back along the line so a filled cap has room and no stroke pokes out
    /// through its apex. Returns the shortened polyline and the angle the cap points along.
    static func shortened(_ points: [NSPoint], by amount: CGFloat) -> ([NSPoint], CGFloat) {
        guard points.count >= 2 else { return (points, 0) }
        let tip = points[points.count - 1]
        let previous = points[points.count - 2]
        let length = DiagramShapePath.distance(previous, tip)
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        guard length > amount, amount > 0 else { return (points, angle) }
        var result = points
        result[result.count - 1] = NSPoint(x: tip.x - cos(angle) * amount,
                                           y: tip.y - sin(angle) * amount)
        return (result, angle)
    }

    /// The mirror of `shortened`, for a cap on the source end.
    static func shortenedFromStart(_ points: [NSPoint], by amount: CGFloat) -> ([NSPoint], CGFloat) {
        guard points.count >= 2 else { return (points, 0) }
        let tip = points[0]
        let next = points[1]
        let length = DiagramShapePath.distance(tip, next)
        let angle = atan2(tip.y - next.y, tip.x - next.x)
        guard length > amount, amount > 0 else { return (points, angle) }
        var result = points
        result[0] = NSPoint(x: tip.x - cos(angle) * amount, y: tip.y - sin(angle) * amount)
        return (result, angle)
    }
}
