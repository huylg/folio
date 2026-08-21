import AppKit

/// A fenced code block: a headered card with a copy button and selectable, highlighted source.
///
/// The card used to be painted *behind* the text by a chain of custom layout fragments, one per
/// line, each reconstructing its slice of the card's fill, border, and corners out of paragraph
/// spacing — because the text lived in the document-wide text view and a view could not own that
/// geometry. As a component it is simply a card with a text view in it: the chrome is drawn
/// once, the corners are one rounded rect, and the padding is layout rather than an attribute
/// smuggled through the paragraph style.
public final class CodeComponentView: HeaderedCardView {

    public let source: String
    public weak var host: BlockHost?

    private let body = TextComponentView()
    private var copyButton: NSButton?
    private var copyResetTimer: Timer?

    public override var cardFillColor: NSColor { Ink.codeBackground }

    public init(label: String, source: String, lines: NSAttributedString,
                metrics: DocumentMetrics, host: BlockHost?) {
        self.source = source
        self.host = host
        super.init(metrics: metrics, label: label)

        copyButton = addHeaderButton(symbol: "doc.on.doc", label: "Copy",
                                     target: self, action: #selector(copySource))

        body.configure(with: Self.codeText(lines), kind: .codeLine(isFirst: true, isLast: true))
        body.translatesAutoresizingMaskIntoConstraints = true
        addSubview(body)

        setAccessibilityRole(.group)
        setAccessibilityLabel("\(label) code")
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    deinit { copyResetTimer?.invalidate() }

    /// Strips the paragraph spacing from the code lines.
    ///
    /// The card owns its own padding now. The spacing on the first and last line existed so the
    /// old layout fragments had something to paint the header strip and the bottom padding out
    /// of; left in place it would be added to the card's padding and the block would grow a dead
    /// band at each end. The indents are kept — they are what makes a wrapped line hang past its
    /// own indentation.
    static func codeText(_ lines: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: lines)
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy()
                    as? NSMutableParagraphStyle else { return }
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return out
    }

    public override func layout() {
        super.layout()
        let insets = metrics.codeCardInsets
        body.frame = NSRect(
            x: 0,
            y: CardChrome.headerHeight + insets.bodyTop,
            width: max(1, bounds.width),
            height: max(1, bounds.height - CardChrome.headerHeight
                            - insets.bodyTop - insets.bodyBottom)
        )
    }

    @objc private func copySource() {
        host?.blockRequestsCopy(source)
        copyButton?.image = NSImage(systemSymbolName: "checkmark",
                                    accessibilityDescription: "Copied")
        copyButton?.contentTintColor = Ink.accent
        copyResetTimer?.invalidate()
        // Transient, and lost if the card scrolls out and its view is recycled. Not worth
        // plumbing through the document.
        copyResetTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.copyButton?.image = NSImage(systemSymbolName: "doc.on.doc",
                                              accessibilityDescription: "Copy")
            self?.copyButton?.contentTintColor = Ink.tertiary
        }
    }

    public static func height(lines: NSAttributedString, width: CGFloat,
                              metrics: DocumentMetrics) -> CGFloat {
        let insets = metrics.codeCardInsets
        let text = TextComponentView.height(of: codeText(lines), width: max(1, width))
        return CardChrome.headerHeight + insets.bodyTop + text + insets.bodyBottom
    }

    public override func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width, height: Self.height(lines: body.attributedString(),
                                                 width: width, metrics: metrics))
    }
}

/// A thematic break.
public final class RuleComponentView: NSView, DimmableComponent {

    public var isDimmed: Bool = false {
        didSet {
            guard isDimmed != oldValue else { return }
            alphaValue = isDimmed ? 0.34 : 1.0
        }
    }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        Ink.hairline.setFill()
        NSRect(x: 0, y: (bounds.height / 2).rounded(), width: bounds.width, height: 1).fill()
    }
}
