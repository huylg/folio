import AppKit

/// A drawn Mermaid diagram, on the same card the rest of Folio's blocks use.
///
/// Headered rather than chrome-less, and the copy button is the reason. Once a diagram is drawn
/// its source is not visible, not selectable, and — since the block is a single attachment
/// character in the text stream, and Find is disabled application-wide (`MainMenu.swift`) — not
/// findable either. The header button is the only route back to what the author wrote. That is
/// also worth remembering when component-wide find lands: node text will be content it cannot
/// reach.
///
/// The view holds **no geometry**. Everything comes from `LaidOutDiagram`, resolved through the
/// host's cache, so the height the document stack reserved and the height that gets drawn are
/// the same number by construction rather than by convention.
public final class DiagramBlockView: HeaderedCardView {

    public let source: String
    public let graph: DiagramGraph
    public weak var host: BlockHost?

    private var copyButton: NSButton?
    private var copyResetTimer: Timer?

    /// One-entry memo so a redraw at an unchanged width is not a dictionary lookup. Mirrors
    /// `TableBlockView.cachedGeometry`.
    private var cached: (width: CGFloat, layout: LaidOutDiagram)?

    public override var cardFillColor: NSColor { Ink.diagramBackground }

    public init(source: String, graph: DiagramGraph, metrics: DocumentMetrics, host: BlockHost?) {
        self.source = source
        self.graph = graph
        self.host = host
        // The header names the kind that was actually drawn. `mermaid ·` is reserved for the
        // source card, where it means "this is what you wrote, undrawn". Whether a wide diagram
        // had to be rotated depends on the width, so that part of the label is filled in during
        // layout rather than guessed here.
        super.init(metrics: metrics, label: graph.displayLabel)

        copyButton = addHeaderButton(symbol: "doc.on.doc", label: "Copy",
                                     target: self, action: #selector(copySource))

        setAccessibilityRole(.group)
        setAccessibilityElement(true)
        setAccessibilityLabel(graph.accessibilityDescription)
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    deinit { copyResetTimer?.invalidate() }

    // MARK: Geometry

    static func contentWidth(for width: CGFloat) -> CGFloat {
        max(1, width - CardChrome.bodyPadding.left - CardChrome.bodyPadding.right)
    }

    /// The one place a laid-out diagram becomes a card height. Both the measure path and the
    /// drawing path go through it, which is what makes them agree.
    static func height(of laid: LaidOutDiagram) -> CGFloat {
        CardChrome.headerHeight + CardChrome.bodyPadding.top
            + laid.size.height + CardChrome.bodyPadding.bottom
    }

    public static func height(
        source: String, graph: DiagramGraph, width: CGFloat,
        metrics: DocumentMetrics, host: BlockHost?
    ) -> CGFloat {
        height(of: resolve(source: source, graph: graph, width: width,
                           metrics: metrics, host: host))
    }

    /// A nil host means no cache — correct, just not memoised. That is the path tests and the
    /// factory's own fallbacks take.
    private static func resolve(
        source: String, graph: DiagramGraph, width: CGFloat,
        metrics: DocumentMetrics, host: BlockHost?
    ) -> LaidOutDiagram {
        let content = contentWidth(for: width)
        if let host {
            return host.diagramLayouts.layout(source: source, graph: graph,
                                              width: content, metrics: metrics)
        }
        return DiagramLayout.layout(graph: graph, width: content, metrics: metrics)
    }

    private func layout(for width: CGFloat) -> LaidOutDiagram {
        if let cached, cached.width == width { return cached.layout }
        let resolved = Self.resolve(source: source, graph: graph, width: width,
                                    metrics: metrics, host: host)
        cached = (width, resolved)
        return resolved
    }

    public override func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width, height: Self.height(of: layout(for: width)))
    }

    public override func layout() {
        super.layout()
        // The stack retains widget views across re-pagination, so a live view can be handed a
        // width it was never laid out against.
        guard bounds.width > 0 else { return }
        let stale = cached?.width != bounds.width
        let resolved = layout(for: bounds.width)
        if headerLabel.stringValue != resolved.headerLabel {
            headerLabel.stringValue = resolved.headerLabel
        }
        if stale { needsDisplay = true }
    }

    // MARK: Drawing

    public override func drawCardContents(in rect: NSRect) {
        super.drawCardContents(in: rect)
        guard rect.width > 0 else { return }
        let padding = CardChrome.bodyPadding
        let body = NSRect(x: padding.left,
                          y: CardChrome.headerHeight + padding.top,
                          width: max(1, rect.width - padding.left - padding.right),
                          height: max(1, rect.height - CardChrome.headerHeight
                                      - padding.top - padding.bottom))
        layout(for: rect.width).draw(in: body)
    }

    // MARK: Copy

    @objc private func copySource() {
        host?.blockRequestsCopy(source)
        copyButton?.image = NSImage(systemSymbolName: "checkmark",
                                    accessibilityDescription: "Copied")
        copyButton?.contentTintColor = Ink.accent
        copyResetTimer?.invalidate()
        copyResetTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.copyButton?.image = NSImage(systemSymbolName: "doc.on.doc",
                                              accessibilityDescription: "Copy")
            self?.copyButton?.contentTintColor = Ink.tertiary
        }
    }
}
