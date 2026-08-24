import AppKit

/// Node outlines and edge caps as pure geometry.
///
/// Every path is derived from the measured box and nothing else, so a shape's outline and the
/// extent the layout reserved for it cannot disagree. That is also what makes the "does the label
/// fit inside the shape" test possible: measurement inflates the box, and the path is built from
/// the inflated box.
enum DiagramShapePath {

    /// The outline of `shape` filling `rect`.
    static func path(for shape: DiagramGraph.Shape, in rect: NSRect) -> NSBezierPath {
        switch shape {
        case .rect, .note, .subroutine:
            return NSBezierPath(rect: rect)

        case .rounded:
            let radius = min(8, rect.height / 2)
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        case .stadium:
            let radius = rect.height / 2
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        case .circle, .stateStart:
            return NSBezierPath(ovalIn: rect)

        case .doubleCircle, .stateEnd:
            return NSBezierPath(ovalIn: rect)

        case .forkJoin:
            let radius = min(rect.width, rect.height) / 2
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        case .diamond, .choice:
            return polygon([
                NSPoint(x: rect.midX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.midY),
                NSPoint(x: rect.midX, y: rect.maxY),
                NSPoint(x: rect.minX, y: rect.midY),
            ])

        case .hexagon:
            let cut = min(14, rect.width / 4)
            return polygon([
                NSPoint(x: rect.minX + cut, y: rect.minY),
                NSPoint(x: rect.maxX - cut, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.midY),
                NSPoint(x: rect.maxX - cut, y: rect.maxY),
                NSPoint(x: rect.minX + cut, y: rect.maxY),
                NSPoint(x: rect.minX, y: rect.midY),
            ])

        case .asymmetric:
            let cut = min(14, rect.width / 4)
            return polygon([
                NSPoint(x: rect.minX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.maxY),
                NSPoint(x: rect.minX, y: rect.maxY),
                NSPoint(x: rect.minX + cut, y: rect.midY),
            ])

        case .parallelogram:
            let skew = min(18, rect.width / 4)
            return polygon([
                NSPoint(x: rect.minX + skew, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.minY),
                NSPoint(x: rect.maxX - skew, y: rect.maxY),
                NSPoint(x: rect.minX, y: rect.maxY),
            ])

        case .parallelogramAlt:
            let skew = min(18, rect.width / 4)
            return polygon([
                NSPoint(x: rect.minX, y: rect.minY),
                NSPoint(x: rect.maxX - skew, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.maxY),
                NSPoint(x: rect.minX + skew, y: rect.maxY),
            ])

        case .trapezoid:
            let skew = min(18, rect.width / 4)
            return polygon([
                NSPoint(x: rect.minX + skew, y: rect.minY),
                NSPoint(x: rect.maxX - skew, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.maxY),
                NSPoint(x: rect.minX, y: rect.maxY),
            ])

        case .trapezoidAlt:
            let skew = min(18, rect.width / 4)
            return polygon([
                NSPoint(x: rect.minX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.minY),
                NSPoint(x: rect.maxX - skew, y: rect.maxY),
                NSPoint(x: rect.minX + skew, y: rect.maxY),
            ])

        case .cylinder:
            let lip = min(12, rect.height / 4)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.minY + lip))
            path.appendArcWithCentre(NSPoint(x: rect.midX, y: rect.minY + lip),
                                     radiusX: rect.width / 2, radiusY: lip,
                                     from: 180, to: 360)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - lip))
            path.appendArcWithCentre(NSPoint(x: rect.midX, y: rect.maxY - lip),
                                     radiusX: rect.width / 2, radiusY: lip,
                                     from: 0, to: 180)
            path.close()
            return path
        }
    }

    /// Extra strokes drawn inside a shape after its fill: a subroutine's side rules, a double
    /// circle's inner ring, a cylinder's lip, a note's fold.
    static func detail(for shape: DiagramGraph.Shape, in rect: NSRect) -> NSBezierPath? {
        switch shape {
        case .subroutine:
            let inset = min(8, rect.width / 5)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY))
            path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY))
            return path

        case .doubleCircle:
            return NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))

        case .cylinder:
            let lip = min(12, rect.height / 4)
            let path = NSBezierPath()
            path.appendOval(in: NSRect(x: rect.minX, y: rect.minY,
                                       width: rect.width, height: lip * 2))
            return path

        case .note:
            let fold = min(12, min(rect.width, rect.height) / 3)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.maxX - fold, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - fold, y: rect.minY + fold))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY + fold))
            return path

        default:
            return nil
        }
    }

    /// The end state is drawn as a ring around a filled core, which is the conventional
    /// state-machine terminator.
    static func stateEndCore(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28))
    }

    // MARK: Boundaries

    /// Where a line from the centre of `rect` toward `target` leaves the shape.
    ///
    /// Three shapes get exact treatment — diamond, ellipse, hexagon — because those are the ones
    /// whose rectangle is a visibly wrong answer. Everything else uses the box, which is correct
    /// for the rectangular family and close enough for the skewed one.
    static func boundary(of shape: DiagramGraph.Shape, in rect: NSRect,
                         toward target: NSPoint) -> NSPoint {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - centre.x
        let dy = target.y - centre.y
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return centre }

        let halfWidth = max(0.5, rect.width / 2)
        let halfHeight = max(0.5, rect.height / 2)

        switch shape {
        case .circle, .doubleCircle, .stateStart, .stateEnd:
            let scale = 1 / sqrt(pow(dx / halfWidth, 2) + pow(dy / halfHeight, 2))
            return NSPoint(x: centre.x + dx * scale, y: centre.y + dy * scale)

        case .diamond, .choice:
            // |x|/a + |y|/b = 1
            let scale = 1 / (abs(dx) / halfWidth + abs(dy) / halfHeight)
            return NSPoint(x: centre.x + dx * scale, y: centre.y + dy * scale)

        case .hexagon:
            let box = rectBoundary(rect, dx: dx, dy: dy)
            let cut = min(14, rect.width / 4)
            // Clip the corner: past the cut, fall back to the hexagon's slanted face.
            let overshootX = max(0, abs(box.x - centre.x) - (halfWidth - cut))
            if overshootX > 0, abs(box.y - centre.y) > halfHeight - 0.5 {
                let scale = 1 / (abs(dx) / halfWidth + abs(dy) / halfHeight)
                return NSPoint(x: centre.x + dx * scale, y: centre.y + dy * scale)
            }
            return box

        default:
            return rectBoundary(rect, dx: dx, dy: dy)
        }
    }

    private static func rectBoundary(_ rect: NSRect, dx: CGFloat, dy: CGFloat) -> NSPoint {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let halfWidth = max(0.5, rect.width / 2)
        let halfHeight = max(0.5, rect.height / 2)
        let scaleX = abs(dx) > 0.0001 ? halfWidth / abs(dx) : CGFloat.greatestFiniteMagnitude
        let scaleY = abs(dy) > 0.0001 ? halfHeight / abs(dy) : CGFloat.greatestFiniteMagnitude
        let scale = min(scaleX, scaleY)
        return NSPoint(x: centre.x + dx * scale, y: centre.y + dy * scale)
    }

    // MARK: Caps

    /// A filled triangle whose apex sits at `tip`, pointing along `angle`.
    static func arrowhead(at tip: NSPoint, angle: CGFloat,
                          length: CGFloat, width: CGFloat) -> NSBezierPath {
        let back = NSPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let normal = NSPoint(x: -sin(angle), y: cos(angle))
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: back.x + normal.x * width / 2, y: back.y + normal.y * width / 2))
        path.line(to: NSPoint(x: back.x - normal.x * width / 2, y: back.y - normal.y * width / 2))
        path.close()
        return path
    }

    static func crossCap(at tip: NSPoint, angle: CGFloat, arm: CGFloat) -> NSBezierPath {
        let centre = NSPoint(x: tip.x - cos(angle) * arm, y: tip.y - sin(angle) * arm)
        let path = NSBezierPath()
        for offset in [CGFloat.pi / 4, -CGFloat.pi / 4] {
            let a = angle + offset
            path.move(to: NSPoint(x: centre.x - cos(a) * arm, y: centre.y - sin(a) * arm))
            path.line(to: NSPoint(x: centre.x + cos(a) * arm, y: centre.y + sin(a) * arm))
        }
        return path
    }

    // MARK: Polylines

    /// A polyline with its corners rounded, clamped so a corner radius can never exceed half of
    /// either adjacent segment — which is what stops a rounded corner from overshooting into the
    /// node it just left. A spline would have no such guarantee.
    static func roundedPolyline(_ points: [NSPoint], radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count >= 2 else { return path }
        guard points.count > 2, radius > 0 else {
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            return path
        }

        path.move(to: points[0])
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1], corner = points[index], next = points[index + 1]
            let inLength = distance(previous, corner)
            let outLength = distance(corner, next)
            let r = min(radius, inLength / 2, outLength / 2)
            guard r > 0.5 else {
                path.line(to: corner)
                continue
            }
            let entry = interpolate(corner, toward: previous, by: r)
            let exit = interpolate(corner, toward: next, by: r)
            path.line(to: entry)
            path.curve(to: exit, controlPoint1: corner, controlPoint2: corner)
        }
        path.line(to: points[points.count - 1])
        return path
    }

    static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func interpolate(_ from: NSPoint, toward: NSPoint, by amount: CGFloat) -> NSPoint {
        let length = distance(from, toward)
        guard length > 0.0001 else { return from }
        let t = amount / length
        return NSPoint(x: from.x + (toward.x - from.x) * t, y: from.y + (toward.y - from.y) * t)
    }

    private static func polygon(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.close()
        return path
    }
}

private extension NSBezierPath {
    /// `appendArc` only takes a circular radius, so an elliptical lip is drawn by scaling a unit
    /// arc through a transform.
    func appendArcWithCentre(_ centre: NSPoint, radiusX: CGFloat, radiusY: CGFloat,
                             from start: CGFloat, to end: CGFloat) {
        let steps = 24
        for step in 0...steps {
            let angle = (start + (end - start) * CGFloat(step) / CGFloat(steps)) * .pi / 180
            let point = NSPoint(x: centre.x + cos(angle) * radiusX,
                                y: centre.y + sin(angle) * radiusY)
            if step == 0, isEmpty {
                move(to: point)
            } else {
                line(to: point)
            }
        }
    }
}
