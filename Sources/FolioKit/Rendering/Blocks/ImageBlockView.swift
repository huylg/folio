import AppKit
import ImageIO

/// Loads and caches document images.
public final class ImageLoader {
    public static let shared = ImageLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private let queue = DispatchQueue(label: "io.elsanow.folio.images", qos: .userInitiated)
    private var pending = 0
    private let lock = NSLock()

    /// Outstanding decodes, so a headless snapshot can wait for quiescence.
    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    /// Pixel dimensions without decoding the image — a header read, microseconds.
    ///
    /// This is what lets `attachmentBounds` return the correct height on the *first* layout
    /// pass. Without it every image is a scroll-position bomb: the block measures as a
    /// placeholder, then grows when the pixels arrive and shoves the reader's place.
    public func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: width, height: height)
    }

    public func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    public func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let hit = cached(url) { completion(hit); return }

        lock.lock(); pending += 1; lock.unlock()
        queue.async { [weak self] in
            let image = NSImage(contentsOf: url)
            DispatchQueue.main.async {
                if let image { self?.cache.setObject(image, forKey: url as NSURL) }
                self?.lock.lock(); self?.pending -= 1; self?.lock.unlock()
                completion(image)
            }
        }
    }

    /// Mean luminance from a tiny downsample, used to decide whether a light image needs
    /// softening in dark mode. Cached by the caller.
    public func isLight(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let small = rep.converting(to: .genericRGB, renderingIntent: .default)
        else { return false }

        var total: CGFloat = 0
        var samples: CGFloat = 0
        let stepX = max(1, small.pixelsWide / 8)
        let stepY = max(1, small.pixelsHigh / 8)
        for x in stride(from: 0, to: small.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: small.pixelsHigh, by: stepY) {
                guard let color = small.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                samples += 1
            }
        }
        guard samples > 0 else { return false }
        return total / samples > 0.75
    }
}

/// A bare-image paragraph, rendered as a figure. The caption is a real paragraph after this
/// view, not part of it, so it stays selectable and findable.
public final class ImageBlockView: BlockCardView {

    private let source: String
    private let alt: String
    private let base: URL
    private let metrics: DocumentMetrics
    private weak var host: BlockHost?

    private let imageView = NSImageView()
    private var placeholder: NSView?
    private var isLightImage = false

    public init(source: String, alt: String, base: URL,
                metrics: DocumentMetrics, host: BlockHost?) {
        self.source = source
        self.alt = alt
        self.base = base
        self.metrics = metrics
        self.host = host
        super.init(frame: .zero)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Alt text belongs on the view: NSTextAttachment has no reliable accessibility
        // surface under TextKit 2, and the view is what assistive technology actually sees.
        setAccessibilityRole(.image)
        setAccessibilityElement(true)
        setAccessibilityLabel(alt.isEmpty ? "Image" : alt)

        configure()
    }

    required public init?(coder: NSCoder) { fatalError("not supported") }

    private func configure() {
        switch Self.classify(source, base: base) {
        case .local(let url):
            if let cached = ImageLoader.shared.cached(url) {
                apply(cached)
            } else {
                ImageLoader.shared.load(url) { [weak self] image in
                    guard let self else { return }
                    if let image { self.apply(image) } else { self.showFailure() }
                }
            }
        case .remote(let url):
            if AppSettings.shared.loadRemoteImages {
                ImageLoader.shared.load(url) { [weak self] image in
                    guard let self else { return }
                    if let image { self.apply(image) } else { self.showFailure() }
                }
            } else {
                showRemotePlaceholder(host: url.host ?? source)
            }
        case .unresolved:
            showFailure()
        }
    }

    private func apply(_ image: NSImage) {
        placeholder?.removeFromSuperview()
        placeholder = nil
        imageView.image = image
        imageView.isHidden = false
        isLightImage = ImageLoader.shared.isLight(image)
        needsDisplay = true
    }

    /// A white-background diagram glows on a dark page. Apple's guidance is to soften it; a
    /// slight alpha reduction plus a hairline border makes it read as a card instead.
    /// A white-background diagram glows on a dark page; Apple's guidance is to soften it.
    private var softensForDarkMode: Bool { isLightImage }

    public override var cardFillColor: NSColor { softensForDarkMode ? Ink.page : .clear }
    public override var cardBorderColor: NSColor { softensForDarkMode ? Ink.hairline : .clear }

    public override func draw(_ dirtyRect: NSRect) {
        imageView.alphaValue = softensForDarkMode ? 0.9 : 1
        super.draw(dirtyRect)
    }

    /// Not fetched by default: a local-file reader that silently makes network requests is a
    /// privacy surprise, so the reader is asked once, per image.
    private func showRemotePlaceholder(host hostName: String) {
        imageView.isHidden = true
        let card = HeaderedCardView(metrics: metrics, label: hostName)
        card.translatesAutoresizingMaskIntoConstraints = false

        let message = NSTextField(labelWithString: alt.isEmpty ? "Remote image" : alt)
        message.font = metrics.ramp.callout()
        message.textColor = Ink.secondary
        message.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "Load Image", target: self, action: #selector(loadRemote))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(message)
        card.addSubview(button)
        NSLayoutConstraint.activate([
            message.topAnchor.constraint(equalTo: card.topAnchor,
                                         constant: CardChrome.headerHeight + 12),
            message.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            button.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 10),
            button.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            button.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12),
        ])
        install(card)
        setAccessibilityLabel("Remote image from \(hostName), not loaded. \(alt)")
    }

    @objc private func loadRemote() {
        guard case .remote(let url) = Self.classify(source, base: base) else { return }
        ImageLoader.shared.load(url) { [weak self] image in
            guard let self else { return }
            if let image { self.apply(image) } else { self.showFailure() }
        }
    }

    /// Never a blank hole: the alt text plus the unresolved path.
    private func showFailure() {
        imageView.isHidden = true
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true

        let label = NSTextField(labelWithString: alt.isEmpty ? "Image not found" : alt)
        label.font = metrics.ramp.callout()
        label.textColor = Ink.secondary
        label.translatesAutoresizingMaskIntoConstraints = false

        let path = NSTextField(labelWithString: source)
        path.font = TypeRamp.fixedPitchMono(ofSize: metrics.ramp.caption().pointSize)
        path.textColor = Ink.tertiary
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(label)
        box.addSubview(path)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            path.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            path.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            path.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),
            path.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
        install(box)
        setAccessibilityLabel("Missing image: \(source). \(alt)")
    }

    private func install(_ view: NSView) {
        placeholder?.removeFromSuperview()
        placeholder = view
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    enum Classification {
        case local(URL)
        case remote(URL)
        case unresolved
    }

    static func classify(_ source: String, base: URL) -> Classification {
        if let url = URL(string: source), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .remote(url)
        }
        switch LinkRouter.resolve(source, relativeTo: base) {
        case .file(let url), .markdown(let url, _): return .local(url)
        default: return .unresolved
        }
    }

    /// Analytic: the native aspect ratio comes from a header-only read, so the height is right
    /// before any pixels are decoded.
    public static func height(source: String, alt: String, base: URL,
                              width: CGFloat, metrics: DocumentMetrics) -> CGFloat {
        switch classify(source, base: base) {
        case .local(let url):
            guard let size = ImageLoader.shared.pixelSize(of: url), size.width > 0 else {
                return placeholderHeight(metrics: metrics)
            }
            // Never upscale past native size.
            let displayWidth = min(width, size.width)
            return (displayWidth * size.height / size.width).rounded()
        case .remote:
            return AppSettings.shared.loadRemoteImages
                ? placeholderHeight(metrics: metrics)
                : CardChrome.headerHeight + 78
        case .unresolved:
            return placeholderHeight(metrics: metrics)
        }
    }

    private static func placeholderHeight(metrics: DocumentMetrics) -> CGFloat {
        let font = metrics.ramp.callout()
        let line = (font.ascender - font.descender + font.leading).rounded()
        return 14 + line + 4 + line + 14
    }

    public override func sizeThatFits(width: CGFloat) -> CGSize {
        CGSize(width: width,
               height: Self.height(source: source, alt: alt, base: base,
                                   width: width, metrics: metrics))
    }
}
