import AppKit

/// A headered card showing monospaced source text.
///
/// Used wherever a block cannot be — or has been asked not to be — rendered richly: a math
/// block with `renderEquations` off or unparseable LaTeX, an unsupported Mermaid diagram type,
/// and verbatim HTML blocks. Unlike the previous HTML version, every one of these gets a
/// working copy button, because the card owns its own text rather than indexing into a shared
/// array that the disabled branches silently desynchronised.
public final class SourceCardView: HeaderedCardView {

    public let source: String
    public weak var host: BlockHost?

    private let body = NSTextField(wrappingLabelWithString: "")
    private var copyButton: NSButton?
    private var copyResetTimer: Timer?

    public override var cardFillColor: NSColor { Ink.codeBackground }

    public init(source: String, label: String, metrics: DocumentMetrics, host: BlockHost?) {
        self.source = source
        self.host = host
        super.init(metrics: metrics, label: label)

        copyButton = addHeaderButton(symbol: "doc.on.doc", label: "Copy",
                                     target: self, action: #selector(copySource))

        // A wrapping label rather than a nested NSTextView: inside an attachment view the
        // frame arrives from `attachmentBounds`, and a label sizes deterministically against a
        // known width, where a text view's intrinsic size fights the constraint and collapses.
        body.isSelectable = true
        body.drawsBackground = false
        body.isBordered = false
        body.attributedStringValue = Self.attributed(source, metrics: metrics)
        body.translatesAutoresizingMaskIntoConstraints = true
        addSubview(body)

        setAccessibilityRole(.group)
        setAccessibilityLabel("\(label) source")
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    deinit { copyResetTimer?.invalidate() }

    private static func attributed(_ source: String, metrics: DocumentMetrics) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = metrics.ramp.monoLineHeight()
        style.maximumLineHeight = metrics.ramp.monoLineHeight()
        style.alignment = .natural
        style.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: source, attributes: [
            .font: metrics.ramp.mono(),
            .foregroundColor: Ink.body,
            .paragraphStyle: style,
        ])
    }

    public override func layout() {
        super.layout()
        let padding = CardChrome.bodyPadding
        body.frame = NSRect(
            x: padding.left,
            y: CardChrome.headerHeight + padding.top,
            width: max(1, bounds.width - padding.left - padding.right),
            height: max(1, bounds.height - CardChrome.headerHeight - padding.top - padding.bottom)
        )
    }

    @objc private func copySource() {
        host?.blockRequestsCopy(source)
        copyButton?.image = NSImage(systemSymbolName: "checkmark",
                                    accessibilityDescription: "Copied")
        copyButton?.contentTintColor = Ink.accent
        copyResetTimer?.invalidate()
        // Transient, and lost if the card scrolls out and its view is recycled. Not worth
        // plumbing through the payload.
        copyResetTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.copyButton?.image = NSImage(systemSymbolName: "doc.on.doc",
                                              accessibilityDescription: "Copy")
            self?.copyButton?.contentTintColor = Ink.tertiary
        }
    }

    /// Computed analytically, without instantiating a view, so the builder can pre-seed the
    /// size cache and TextKit never resorts to an estimated height for this block.
    public static func height(source: String, width: CGFloat, metrics: DocumentMetrics) -> CGFloat {
        let padding = CardChrome.bodyPadding
        let available = max(1, width - padding.left - padding.right)
        let line = metrics.ramp.monoLineHeight()
        let measured = attributed(source, metrics: metrics).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lines = max(1, Int((measured.height / line).rounded(.up)))
        return CardChrome.headerHeight + padding.top
            + CGFloat(lines) * line + padding.bottom
    }

    public override func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width, height: Self.height(source: source, width: width, metrics: metrics))
    }
}
