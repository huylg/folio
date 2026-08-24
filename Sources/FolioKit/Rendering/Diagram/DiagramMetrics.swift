import AppKit

/// Every spacing constant a diagram needs, derived from the document's own type ramp.
///
/// Sizes scale with `ramp.scale` and the gaps additionally with density, so ⌘+ and the density
/// control move a diagram exactly as far as they move the prose beside it. A diagram that stayed
/// put while the text grew would read as a screenshot pasted into the page.
///
/// This is also the single place node and label measurement lives. The layout, the router and the
/// drawing all size boxes from here, which is what keeps a shape's path and its measured extent
/// from ever disagreeing.
public struct DiagramMetrics {

    public let document: DocumentMetrics
    private let s: CGFloat
    private let gap: CGFloat

    public init(document: DocumentMetrics) {
        self.document = document
        self.s = document.ramp.scale
        self.gap = document.density == .compact ? 0.82 : 1.0
    }

    private func pt(_ value: CGFloat) -> CGFloat { (value * s).rounded() }
    private func gapPt(_ value: CGFloat) -> CGFloat { (value * s * gap).rounded() }

    // MARK: Boxes

    public var nodePadding: NSEdgeInsets {
        NSEdgeInsets(top: pt(9), left: pt(14), bottom: pt(9), right: pt(14))
    }
    public var minNodeSize: CGSize { CGSize(width: pt(44), height: pt(30)) }
    /// Width a label wraps at before it is allowed to grow the node.
    public var maxLabelWidth: CGFloat { pt(168) }

    /// How far a hexagon's corners are cut in, which is also the room its label needs to clear
    /// them. Must match `DiagramShapePath`'s own cut.
    public var hexagonCut: CGFloat { pt(14) }

    public var startMarkerSize: CGFloat { pt(14) }
    public var endMarkerSize: CGFloat { pt(18) }
    public var forkBarThickness: CGFloat { pt(6) }
    public var forkBarLength: CGFloat { pt(64) }
    public var choiceSize: CGFloat { pt(26) }

    // MARK: Gaps

    public var nodeGap: CGFloat { gapPt(26) }
    public var rankGap: CGFloat { gapPt(46) }
    /// The across-axis room a virtual node reserves, so a long edge routes past a rank rather
    /// than through it.
    public var virtualNodeExtent: CGFloat { pt(10) }
    public var clusterPadding: CGFloat { gapPt(16) }
    public var clusterTitleHeight: CGFloat { pt(20) }
    public var selfLoopExtent: CGFloat { pt(26) }
    public var parallelEdgeSpread: CGFloat { pt(12) }
    /// Padding inside the card, around the whole drawing.
    public var canvasPadding: CGFloat { pt(18) }

    // MARK: Marks

    public var arrowLength: CGFloat { pt(9) }
    public var arrowWidth: CGFloat { pt(7) }
    public var edgeCornerRadius: CGFloat { pt(8) }
    public var capCircleRadius: CGFloat { pt(4) }
    public var capCrossArm: CGFloat { pt(4) }
    public var labelChipPadding: CGSize { CGSize(width: pt(6), height: pt(2)) }

    public var edgeLineWidth: CGFloat { max(1, pt(1.25)) }
    public var thickEdgeLineWidth: CGFloat { max(1.5, pt(2.5)) }
    public var nodeBorderWidth: CGFloat { max(1, pt(1)) }
    public var dashPattern: [CGFloat] { [pt(2), pt(3)] }

    // MARK: Text

    /// Node labels use callout rather than caption: caption is already small before the whole
    /// diagram is scaled down to fit a column.
    public func nodeLabelAttributes() -> [NSAttributedString.Key: Any] {
        [.font: document.ramp.callout(),
         .foregroundColor: Ink.body,
         .paragraphStyle: centred()]
    }

    public func edgeLabelAttributes() -> [NSAttributedString.Key: Any] {
        [.font: document.ramp.caption(),
         .foregroundColor: Ink.secondary,
         .paragraphStyle: centred()]
    }

    public func clusterTitleAttributes() -> [NSAttributedString.Key: Any] {
        [.font: document.ramp.caption(),
         .foregroundColor: Ink.tertiary,
         .paragraphStyle: centred(alignment: .natural)]
    }

    private func centred(alignment: NSTextAlignment = .center) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        return style
    }

    public func attributed(_ label: DiagramGraph.Label,
                           attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: label.lines.joined(separator: "\n"), attributes: attributes)
    }

    /// Measured at the wrap width, so an author's hard break and an automatic wrap are resolved
    /// in one pass and the result is what will actually be drawn.
    public func textSize(_ label: DiagramGraph.Label,
                         attributes: [NSAttributedString.Key: Any],
                         wrappingAt width: CGFloat) -> CGSize {
        guard !label.isEmpty else { return .zero }
        let bounds = attributed(label, attributes: attributes).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: bounds.width.rounded(.up), height: bounds.height.rounded(.up))
    }

    // MARK: Node measurement

    /// The box a node occupies, before the layout projects it onto the rank axes.
    ///
    /// `direction` matters only for the fork/join bar, which is a rule across the flow and so
    /// swaps its axes with the flow.
    public func nodeSize(for node: DiagramGraph.Node,
                         direction: DiagramGraph.Direction) -> CGSize {
        switch node.shape {
        case .stateStart:
            return CGSize(width: startMarkerSize, height: startMarkerSize)
        case .stateEnd:
            return CGSize(width: endMarkerSize, height: endMarkerSize)
        case .forkJoin:
            return direction.isVertical
                ? CGSize(width: forkBarLength, height: forkBarThickness)
                : CGSize(width: forkBarThickness, height: forkBarLength)
        case .choice:
            return CGSize(width: choiceSize, height: choiceSize)
        default:
            break
        }

        let text = textSize(node.label, attributes: nodeLabelAttributes(),
                            wrappingAt: maxLabelWidth)
        let padding = nodePadding
        var width = text.width + padding.left + padding.right
        var height = text.height + padding.top + padding.bottom

        switch node.shape {
        case .diamond:
            // Twice the text box, rather than a fudge factor. This is the condition that
            // actually guarantees a fit: with half-axes `a = tw + hpad` and `b = th + vpad`, the
            // label's corner satisfies `|x|/a + |y|/b < 1` for any padding above zero. A
            // multiplier only happens to work at one aspect ratio, which is how a diamond's text
            // ends up poking out of both points.
            width = text.width * 2 + padding.left + padding.right
            height = text.height * 2 + padding.top + padding.bottom
        case .hexagon:
            // The label has to clear both cut corners at its own top and bottom edges.
            width += hexagonCut * 2
        case .trapezoid, .trapezoidAlt, .parallelogram, .parallelogramAlt: width += pt(24)
        case .subroutine: width += pt(16)
        case .cylinder: height += pt(10)
        case .note: width += pt(10)
        default: break
        }

        width = max(width, minNodeSize.width)
        height = max(height, minNodeSize.height)

        if node.shape.isRound {
            // A circle is defined by one radius, so the box has to be square or the label
            // escapes through the sides.
            let side = max(width, height)
            return CGSize(width: side.rounded(), height: side.rounded())
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// The chip drawn over an edge, including its knockout padding.
    public func edgeLabelSize(_ label: DiagramGraph.Label) -> CGSize {
        let text = textSize(label, attributes: edgeLabelAttributes(), wrappingAt: maxLabelWidth)
        guard text.width > 0 else { return .zero }
        return CGSize(width: (text.width + labelChipPadding.width * 2).rounded(),
                      height: (text.height + labelChipPadding.height * 2).rounded())
    }
}
