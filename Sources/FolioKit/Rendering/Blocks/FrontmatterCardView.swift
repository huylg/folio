import AppKit

/// The YAML frontmatter card shown above the document title.
public final class FrontmatterCardView: BlockCardView {

    private let frontmatter: Frontmatter
    private let metrics: DocumentMetrics
    private weak var host: BlockHost?

    private static let padding = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    private static let keyColumnWidth: CGFloat = 88
    private static let columnSpacing: CGFloat = 16
    private static let rowSpacing: CGFloat = 6
    private static let headerSpacing: CGFloat = 10

    /// The value labels, so `layout()` can tell them how wide they may be.
    private var valueLabels: [LinkLabel] = []

    public init(frontmatter: Frontmatter, metrics: DocumentMetrics, host: BlockHost?) {
        self.frontmatter = frontmatter
        self.metrics = metrics
        self.host = host
        super.init(frame: .zero)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = Ink.tertiary
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: metrics.ramp.caption().pointSize, weight: .semibold
        )
        header.addArrangedSubview(chevron)

        let title = NSTextField(labelWithString: "FRONTMATTER")
        title.font = NSFont.systemFont(ofSize: metrics.ramp.caption().pointSize, weight: .semibold)
        title.textColor = Ink.tertiary
        // The design's 0.04em tracking on the uppercase label.
        title.attributedStringValue = NSAttributedString(
            string: "FRONTMATTER",
            attributes: [
                .font: NSFont.systemFont(ofSize: metrics.ramp.caption().pointSize, weight: .semibold),
                .foregroundColor: Ink.tertiary,
                .kern: metrics.ramp.caption().pointSize * 0.04,
            ]
        )
        header.addArrangedSubview(title)

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Self.rowSpacing
        grid.columnSpacing = Self.columnSpacing

        for key in frontmatter.orderedKeys {
            guard let value = frontmatter.values[key] else { continue }
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = TypeRamp.fixedPitchMono(ofSize: metrics.ramp.caption().pointSize)
            keyLabel.textColor = Ink.tertiary

            let valueView: NSView
            if Self.isTagKey(key), case .list(let items) = value {
                valueView = Self.tagRow(items, metrics: metrics)
            } else {
                let label = LinkLabel(attributed: NSAttributedString(
                    string: value.display,
                    attributes: [.font: metrics.ramp.callout(), .foregroundColor: Ink.heading]
                ))
                label.host = host
                valueLabels.append(label)
                valueView = label
            }
            grid.addRow(with: [keyLabel, valueView])
        }
        // Only valid once a row exists — an empty NSGridView has no columns.
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .leading
            grid.column(at: 0).width = Self.keyColumnWidth
        }

        addSubview(header)
        addSubview(grid)

        let p = Self.padding
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: p.top),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.left),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.headerSpacing),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.left),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -p.right),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -p.bottom),
            grid.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.keyColumnWidth),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Frontmatter, \(frontmatter.orderedKeys.count) fields")
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    private static func isTagKey(_ key: String) -> Bool {
        ["tags", "tag", "keywords"].contains(key)
    }

    private static func tagRow(_ tags: [String], metrics: DocumentMetrics) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        for tag in tags {
            row.addArrangedSubview(TagPillView(tag: tag, metrics: metrics))
        }
        return row
    }

    /// Width a value may occupy: the card less its padding, the key column, and the gutter.
    static func valueWidth(cardWidth: CGFloat) -> CGFloat {
        max(40, cardWidth - padding.left - padding.right - keyColumnWidth - columnSpacing)
    }

    /// The height one value needs at that width.
    ///
    /// Measured with the same kind of label that will draw it, at the same width, so the height
    /// reserved for the card and the height its content actually takes cannot disagree — a
    /// disagreement here either clips the last row or leaves a gap under it.
    static func valueHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let probe = NSTextField(labelWithString: text)
        probe.font = font
        probe.lineBreakMode = .byWordWrapping
        probe.maximumNumberOfLines = 0
        probe.preferredMaxLayoutWidth = width
        return probe.fittingSize.height.rounded(.up)
    }

    /// Analytic height, so the stack can measure the card without building it.
    public static func height(
        frontmatter: Frontmatter,
        width: CGFloat,
        metrics: DocumentMetrics
    ) -> CGFloat {
        let font = metrics.ramp.callout()
        let lineHeight = max(
            (font.ascender - font.descender + font.leading).rounded(),
            TagPillView.height(metrics: metrics)
        )
        let caption = metrics.ramp.caption()
        let headerHeight = (caption.ascender - caption.descender + caption.leading).rounded()
        let available = valueWidth(cardWidth: width)

        // Per row rather than a flat row height: a long value — a subtitle, a list of authors —
        // wraps, and a flat height had it overflow the card's right padding instead.
        var rowsHeight: CGFloat = 0
        for key in frontmatter.orderedKeys {
            guard let value = frontmatter.values[key] else { continue }
            if isTagKey(key), case .list = value {
                rowsHeight += lineHeight
            } else {
                rowsHeight += max(lineHeight,
                                  valueHeight(value.display, font: font, width: available))
            }
        }
        let rows = CGFloat(frontmatter.orderedKeys.count)
        return padding.top + headerHeight + headerSpacing
            + rowsHeight + max(0, rows - 1) * rowSpacing
            + padding.bottom
    }

    public override func layout() {
        super.layout()
        // A multi-line `NSTextField` reports a single-line intrinsic width until it is told what
        // width to wrap at. Without this the label kept its full natural width, the grid's
        // trailing constraint could not be satisfied, and the value ran out through the card's
        // right padding.
        let available = Self.valueWidth(cardWidth: bounds.width)
        for label in valueLabels where label.preferredMaxLayoutWidth != available {
            label.preferredMaxLayoutWidth = available
        }
        layoutSubtreeIfNeeded()
    }

    public override func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width,
               height: Self.height(frontmatter: frontmatter, width: width, metrics: metrics))
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
