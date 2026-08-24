import AppKit

/// Maps a block payload to its widget view, and — separately — to its height.
///
/// The height path must work *without* building a view, because the document stack measures
/// every component before it builds the handful that are near the viewport.
public enum BlockViewFactory {

    public static func makeView(for payload: BlockPayload, host: BlockHost?) -> NSView {
        if ProcessInfo.processInfo.environment["FOLIO_PLAIN_BLOCKS"] != nil {
            return DebugProbeView()
        }
        let metrics = host?.blockMetrics ?? DocumentMetrics(settings: .shared)

        switch payload {
        case .table(let spec):
            return TableBlockView(spec: spec, metrics: metrics, host: host)

        case .frontmatter(let frontmatter):
            return FrontmatterCardView(frontmatter: frontmatter, metrics: metrics, host: host)

        case .image(let source, let alt, let base):
            return ImageBlockView(source: source, alt: alt, base: base,
                                  metrics: metrics, host: host)

        case .math(let latex, _):
            // Native math layout lands in a later phase; until then the source card is
            // exactly what the previous renderer produced for this block.
            return SourceCardView(source: latex, label: "latex", metrics: metrics, host: host)

        case .diagram(let source, let graph):
            guard let graph else {
                return SourceCardView(source: source, label: sourceLabel(for: source),
                                      metrics: metrics, host: host)
            }
            return DiagramBlockView(source: source, graph: graph, metrics: metrics, host: host)

        case .htmlBlock(let html):
            return SourceCardView(source: html, label: "html", metrics: metrics, host: host)
        }
    }

    public static func height(
        for payload: BlockPayload,
        width: CGFloat,
        metrics: DocumentMetrics,
        host: BlockHost? = nil
    ) -> CGFloat {
        switch payload {
        case .table(let spec):
            return TableBlockView.height(spec: spec, width: width, metrics: metrics)
        case .frontmatter(let frontmatter):
            return FrontmatterCardView.height(frontmatter: frontmatter, width: width, metrics: metrics)
        case .image(let source, let alt, let base):
            return ImageBlockView.height(source: source, alt: alt, base: base,
                                         width: width, metrics: metrics)
        case .math(let latex, _):
            return SourceCardView.height(source: latex, width: width, metrics: metrics)
        case .diagram(let source, let graph):
            guard let graph else {
                return SourceCardView.height(source: source, width: width, metrics: metrics)
            }
            return DiagramBlockView.height(source: source, graph: graph, width: width,
                                           metrics: metrics, host: host)
        case .htmlBlock(let html):
            return SourceCardView.height(source: html, width: width, metrics: metrics)
        }
    }

    /// The label for a diagram Folio does **not** draw: the kind the author declared, behind a
    /// reserved `mermaid ·` prefix.
    ///
    /// A drawn diagram gets its resolved kind bare (`flowchart LR`), so the prefix now carries a
    /// specific meaning — "this is what you wrote, undrawn" — and an unsupported kind still
    /// cannot be mistaken for a rendered one.
    static func sourceLabel(for source: String) -> String {
        guard let keyword = DiagramParser.declaredKeyword(source) else { return "mermaid" }
        return "mermaid · \(keyword)"
    }
}


/// Debug-only: a flat filled rectangle used to tell whether a rendering artifact comes from a
/// widget's own drawing or from how attachment views are hosted.
final class DebugProbeView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.35).setFill()
        bounds.fill()
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}
