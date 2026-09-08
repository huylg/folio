import AppKit

/// Frontmatter text uses the same TextKit layout for painting, measurement and selection.
public final class FrontmatterCardView: BlockCardView, DocumentSurfaceProvider, SelectionPaintOwner {
    private let frontmatter: Frontmatter
    private let metrics: DocumentMetrics
    private weak var host: BlockHost?
    weak var selectionStack: DocumentStackView?
    private var cachedWidth: CGFloat = -1
    private var records: [Record] = []
    private var layouts: [SelectionTextLayout] = []
    private var surfaces: [TextSelectionSurface] = []

    private static let padding: CGFloat = 16
    private static let keyColumnWidth: CGFloat = 88
    private static let columnSpacing: CGFloat = 16
    private static let rowSpacing: CGFloat = 6

    private struct Record {
        let part: DocumentTextIndex.Part
        let text: NSAttributedString
        let frame: NSRect
        var pill: NSColor? = nil
    }

    public init(frontmatter: Frontmatter, metrics: DocumentMetrics, host: BlockHost?) {
        self.frontmatter = frontmatter; self.metrics = metrics; self.host = host
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Frontmatter")
    }
    required public init?(coder: NSCoder) { fatalError("not supported") }

    static func valueWidth(cardWidth: CGFloat) -> CGFloat {
        max(40, cardWidth - 2 * padding - keyColumnWidth - columnSpacing)
    }
    static func valueHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        TextMeasurer.shared.height(of: attributed(text, font: font, color: Ink.heading), width: width)
    }
    private static func attributed(_ string: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }
    private static func arrange(_ frontmatter: Frontmatter, width: CGFloat,
                                metrics: DocumentMetrics) -> (CGFloat, [Record]) {
        let valueX = padding + keyColumnWidth + columnSpacing
        let available = valueWidth(cardWidth: width)
        let font = metrics.ramp.callout()
        let caption = metrics.ramp.caption()
        var y: CGFloat = 14 + (caption.ascender - caption.descender + caption.leading).rounded() + 10
        var records: [Record] = []
        for key in frontmatter.orderedKeys {
            guard let value = frontmatter.values[key] else { continue }
            let keyText = attributed(key, font: TypeRamp.fixedPitchMono(ofSize: caption.pointSize), color: Ink.tertiary)
            let keyHeight = TextMeasurer.shared.height(of: keyText, width: keyColumnWidth)
            records.append(Record(part: .key(key), text: keyText,
                frame: NSRect(x: padding, y: y, width: keyColumnWidth, height: keyHeight)))
            var rowHeight = max(keyHeight, TagPillView.height(metrics: metrics))
            if DocumentTextIndex.isTagKey(key), case .list(let tags) = value {
                var x: CGFloat = 0, tagY: CGFloat = 0
                var lineHeight: CGFloat = 0
                for (i, tag) in tags.enumerated() {
                    let colors = TagPalette.pill(for: tag)
                    let text = attributed(tag, font: NSFont.systemFont(ofSize: caption.pointSize, weight: .medium),
                                          color: colors.text)
                    let natural = TextMeasurer.shared.size(of: text, width: available).width
                    let tagWidth = min(available, natural + 16)
                    if x > 0 && x + tagWidth > available { x = 0; tagY += lineHeight + 4; lineHeight = 0 }
                    let height = TextMeasurer.shared.height(of: text, width: max(1, tagWidth - 16))
                    records.append(Record(part: .tag(key, i), text: text,
                        frame: NSRect(x: valueX + x + 8, y: y + tagY + 2,
                                      width: max(1, tagWidth - 16), height: height), pill: colors.fill))
                    lineHeight = max(lineHeight, height + 4)
                    x += tagWidth + 6
                }
                rowHeight = max(rowHeight, tagY + lineHeight)
            } else {
                let text = attributed(value.display, font: font, color: Ink.heading)
                let height = TextMeasurer.shared.height(of: text, width: available)
                records.append(Record(part: .value(key), text: text,
                    frame: NSRect(x: valueX, y: y, width: available, height: height)))
                rowHeight = max(rowHeight, height)
            }
            y += rowHeight + rowSpacing
        }
        return (y - (records.isEmpty ? 0 : rowSpacing) + 14, records)
    }
    public static func height(frontmatter: Frontmatter, width: CGFloat, metrics: DocumentMetrics) -> CGFloat {
        arrange(frontmatter, width: width, metrics: metrics).0
    }
    public override func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width, height: Self.height(frontmatter: frontmatter, width: width, metrics: metrics))
    }
    func documentSurfaces() -> [TextSelectionSurface] {
        guard cachedWidth != bounds.width else { return surfaces }
        cachedWidth = bounds.width
        records = Self.arrange(frontmatter, width: bounds.width, metrics: metrics).1
        layouts = records.map { record in
            let layout = SelectionTextLayout(record.text)
            layout.layout(width: record.frame.width)
            return layout
        }
        surfaces = zip(records, layouts).map { record, layout in
            TextSelectionSurface(view: self, part: record.part, frame: record.frame,
                                 manager: layout.manager, attributed: record.text)
        }
        return surfaces
    }
    public override func drawCardContents(in rect: NSRect) {
        Self.attributed("›  FRONTMATTER", font: metrics.ramp.caption(), color: Ink.tertiary)
            .draw(at: NSPoint(x: Self.padding, y: 14))
        _ = documentSurfaces()
        for (i, surface) in surfaces.enumerated() {
            if let color = records[i].pill {
                color.setFill()
                NSBezierPath(roundedRect: surface.frame.insetBy(dx: -8, dy: -2), xRadius: 8, yRadius: 8).fill()
            }
            if let selectionStack { surface.paint(controller: selectionStack.selectionController) }
            layouts[i].draw(at: surface.frame.origin)
        }
    }
    public override func accessibilityChildren() -> [Any]? {
        documentSurfaces().map(\.accessibilityElement)
    }
}

/// A pill-shaped tag chip. Colors come from `TagPalette`, shared with the sidebar so the same
/// tag reads the same color in both places.
public final class TagPillView: NSView {
    private let tagName: String
    private let label = NSTextField(labelWithString: "")
    private let metrics: DocumentMetrics

    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 2

    public init(tag: String, metrics: DocumentMetrics) {
        self.tagName = tag
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let colors = TagPalette.pill(for: tagName)
        label.stringValue = tagName
        label.font = NSFont.systemFont(ofSize: metrics.ramp.caption().pointSize, weight: .medium)
        label.textColor = colors.text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Tag: \(tagName)")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = bounds.height / 2
        layer.backgroundColor = TagPalette.pill(for: tagName).fill.cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        label.textColor = TagPalette.pill(for: tagName).text
        needsDisplay = true
    }

    public static func height(metrics: DocumentMetrics) -> CGFloat {
        let font = NSFont.systemFont(ofSize: metrics.ramp.caption().pointSize, weight: .medium)
        return (font.ascender - font.descender).rounded() + 2 * verticalPadding
    }
}
