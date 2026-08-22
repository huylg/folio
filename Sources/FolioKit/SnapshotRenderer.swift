import AppKit

/// Renders a document to a PNG offscreen, for eyeballing the reading pane without launching
/// the app.
///
/// Several non-obvious requirements, each learned the hard way:
///
/// 1. **A real window is required.** Several components only lay out and draw correctly inside
///    one, and the window is ordered *back*, not out — `orderOut` detaches the view hierarchy.
/// 2. **Appearance must be forced explicitly** on both the application and the window. Every
///    color in the design is dynamic, and with no window there is nothing to inherit from.
/// 3. **The window has to grow to the document's height.** The stack builds only the components
///    near its viewport, so anything below a short window would capture blank.
/// 4. **The run loop must drain** or asynchronous image decodes are captured as placeholders.
public enum SnapshotRenderer {

    public struct Options {
        public var width: CGFloat = 900
        /// Replaces the relative "Last edited 3 days ago" with a stable string, so snapshots
        /// can be diffed.
        public var fixedDate = true
        public var maxHeight: CGFloat = 20000
        /// Captures one screenful at this window height instead of the whole document.
        ///
        /// Pagination depends on the height of the window: a two-column spread is exactly as tall
        /// as the pane it is read in. Growing the window to the document, which is what makes a
        /// full-length snapshot possible, therefore produces a layout no reader ever sees. Set
        /// this and the window keeps the height given, and the capture is the page at `page`.
        public var viewportHeight: CGFloat = 0
        public var page: Int = 0

        public init() {}
    }

    public static func render(markdown url: URL, to output: URL, options: Options) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        // Folio is dark only.
        let appearance = NSAppearance(named: .darkAqua)!
        app.appearance = appearance

        let document = try MarkdownDocument(url: url)
        let metrics = DocumentMetrics(settings: .shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: options.width, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance

        let documentView = NativeDocumentView(metrics: metrics)
        documentView.usesOpaqueBackground = true
        documentView.frame = NSRect(x: 0, y: 0, width: options.width, height: 800)
        window.contentView = documentView
        window.orderBack(nil)

        documentView.render(document: document, metrics: metrics)
        documentView.layoutSubtreeIfNeeded()

        if options.viewportHeight > 0 {
            window.setContentSize(NSSize(width: options.width, height: options.viewportHeight))
            documentView.frame = NSRect(x: 0, y: 0,
                                       width: options.width, height: options.viewportHeight)
            documentView.layoutSubtreeIfNeeded()
            documentView.reflowForSnapshot()
            drainRunLoop(documentView: documentView)
            documentView.showPageForSnapshot(options.page)
            drainRunLoop(documentView: documentView)
            try capture(documentView, to: output)
            return
        }

        // Grow the window to the document's full height, then let the stack fill it.
        //
        // The stack only builds the components near its viewport, so a window left at its
        // starting height would capture the first screenful and blank paper below it. Two passes:
        // the first grows the window to the measured height, the second lets components that
        // resolved a real height on being built (an image, say) settle.
        var height: CGFloat = 0
        for _ in 0..<3 {
            let measured = documentView.stackView.frame.height
            let clamped = min(max(measured, 200), options.maxHeight)
            guard abs(clamped - height) > 1 else { break }
            height = clamped

            window.setContentSize(NSSize(width: options.width, height: height))
            documentView.frame = NSRect(x: 0, y: 0, width: options.width, height: height)
            documentView.layoutSubtreeIfNeeded()
            documentView.reflowForSnapshot()
            documentView.stackView.populateVisible()
            drainRunLoop(documentView: documentView)
        }

        documentView.layoutSubtreeIfNeeded()
        documentView.stackView.populateVisible()
        drainRunLoop(documentView: documentView)

        try capture(documentView, to: output)
    }

    private static func capture(_ view: NSView, to output: URL) throws {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotError.cannotAllocateBitmap
        }
        // `cacheDisplay` walks subviews, which is what captures every component. A
        // `CALayer.render(in:)` approach would miss them.
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.cannotEncodePNG
        }
        try data.write(to: output)
    }

    private static func drainRunLoop(documentView: NativeDocumentView) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let busy = ImageLoader.shared.pendingCount > 0 || documentView.pendingWorkCount > 0
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if !busy { break }
        }
        // A few extra turns let AppKit finish constraint and viewport work.
        for _ in 0..<8 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    enum SnapshotError: Error, CustomStringConvertible {
        case cannotAllocateBitmap
        case cannotEncodePNG

        var description: String {
            switch self {
            case .cannotAllocateBitmap: return "could not allocate a bitmap for the snapshot"
            case .cannotEncodePNG: return "could not encode the snapshot as PNG"
            }
        }
    }
}
