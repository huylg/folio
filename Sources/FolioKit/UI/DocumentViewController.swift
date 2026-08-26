import AppKit

/// The reading pane: the native TextKit 2 document view and the controls over it.
///
/// Nothing but a document. The "no document open" state is a screen of its own —
/// `WelcomeViewController` — rather than a sibling view hidden behind this one.
public final class DocumentViewController: NSViewController {

    public var onHeadingChange: ((Int) -> Void)?
    /// Every section on screen, so the outline can mark the group rather than one row.
    public var onVisibleSectionsChange: ((Set<Int>) -> Void)?
    public var onOpenRelativeLink: ((URL, String?) -> Void)?

    private var documentView: NativeDocumentView!

    private var document: MarkdownDocument?
    private var textScale: CGFloat = 1
    private var metrics = DocumentMetrics(settings: .shared)

    /// The document stack, for tests that need to inspect layout state.
    var readingStack: DocumentStackView? { documentView?.stackView }
    var readingPaneForTests: NativeDocumentView? { documentView }

    public override func loadView() {
        view = NSView()
        view.wantsLayer = true

        documentView = NativeDocumentView(metrics: metrics)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.linkHandler = self
        documentView.onHeadingChange = { [weak self] index in self?.onHeadingChange?(index) }
        documentView.onVisibleSectionsChange = { [weak self] indices in
            self?.onVisibleSectionsChange?(indices)
        }

        view.addSubview(documentView)

        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: view.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        view.setFrameSize(NSSize(width: 800, height: 600))
    }

    // MARK: Rendering

    public func render(document: MarkdownDocument, preserveScroll: Bool = false) {
        self.document = document

        // A semantic anchor, not a pixel offset: the only thing that triggers a re-render is a
        // font, width, or density change, which reflows the document and makes a saved pixel
        // offset meaningless exactly when it would be used.
        let anchor = preserveScroll ? documentView.captureScrollAnchor() : nil

        metrics = DocumentMetrics(settings: .shared, presentationScale: textScale)
        documentView.render(document: document, metrics: metrics)

        if let anchor { documentView.restore(anchor) }
    }

    // MARK: Live controls

    public func scrollTo(anchor: String) {
        documentView.scroll(toAnchor: anchor)
    }

    /// The section opened by outline entry `index`, for the sidebar's press-to-peek card:
    /// the document's own components, and the metrics they were built against, so the card
    /// renders them exactly as this pane does.
    ///
    /// Strictly read-only against the built document: peeking must never move the reading
    /// position, so nothing on this path may scroll or touch `readingAnchor`.
    public func sectionPreview(forOutlineIndex index: Int) -> SectionPreview? {
        guard let built = documentView?.built else { return nil }
        let components = SectionPreviewBuilder.components(forOutlineIndex: index, in: built)
        guard !components.isEmpty else { return nil }
        return SectionPreview(components: components, metrics: metrics)
    }

    /// Presentation mode. Unlike the CSS version, which scaled only the body size and left all
    /// chrome at fixed pixel sizes, this folds into the type ramp — so card headers, table
    /// cells, captions, and tag pills all scale together, and the measure grows with them.
    public func setTextScale(_ scale: Double) {
        textScale = CGFloat(scale)
        applySettingsLive()
    }

    /// Re-derives fonts and spacing without re-parsing the document.
    public func applySettingsLive() {
        metrics = DocumentMetrics(settings: .shared, presentationScale: textScale)
        documentView.updateMetrics(metrics)
        if let document {
            let anchor = documentView.captureScrollAnchor()
            documentView.render(document: document, metrics: metrics)
            documentView.restore(anchor)
        }
    }
}

extension DocumentViewController: DocumentLinkHandler {
    public func documentView(_ view: NativeDocumentView, openMarkdown url: URL, fragment: String?) {
        onOpenRelativeLink?(url, fragment)
    }
}
