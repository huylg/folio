import AppKit

extension Notification.Name {
    public static let folioSettingsChanged = Notification.Name("folioSettingsChanged")
}

/// UserDefaults-backed app settings. Folio is a read-only viewer: these preferences and the
/// recents list are the only things it ever persists.
public final class AppSettings {
    public static let shared = AppSettings()
    private let d = UserDefaults.standard

    public enum ReadingFont: String, CaseIterable {
        case serif, sansSerif, monospaced

        public var displayName: String {
            switch self {
            case .serif: return "New York (serif)"
            case .sansSerif: return "San Francisco (sans)"
            case .monospaced: return "SF Mono (monospaced)"
            }
        }
    }

    public enum LineWidth: String, CaseIterable {
        case narrow, comfortable, wide

        public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        /// The reading measure in characters, not pixels, so the column scales with the text
        /// size. Apple publishes no line-length guidance for macOS — `readableContentGuide`
        /// is UIKit only — so this band is typographic convention rather than a platform rule.
        public var characters: Int {
            switch self {
            case .narrow: return 62
            case .comfortable: return 72
            case .wide: return 84
            }
        }
    }

    public enum Density: String, CaseIterable {
        case airy, compact

        public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        /// Feeds `NSParagraphStyle.lineHeightMultiple`. Apple's one direct statement for
        /// long-form reading: "when you display text in wide columns or long passages, more
        /// space between lines can make it easier for people to keep their place."
        public var lineHeightMultiple: CGFloat { self == .airy ? 1.72 : 1.5 }
    }

    /// Body point size bounds. The floor is Apple's documented 10pt minimum plus one; the
    /// ceiling is 200% of the 13pt HIG default, which is the accessibility target the HIG
    /// names ("give people the option to enlarge text by at least 200 percent").
    public static let minTextSize = 11
    public static let maxTextSize = 26
    public static let defaultTextSize = 13

    private func notify() {
        NotificationCenter.default.post(name: .folioSettingsChanged, object: self)
    }

    public var readingFont: ReadingFont {
        get { ReadingFont(rawValue: d.string(forKey: "readingFont") ?? "") ?? .serif }
        set { d.set(newValue.rawValue, forKey: "readingFont"); notify() }
    }
    public var textSize: Int {
        get {
            let v = d.integer(forKey: "textSize")
            guard v != 0 else { return Self.defaultTextSize }
            return min(max(v, Self.minTextSize), Self.maxTextSize)
        }
        set {
            d.set(min(max(newValue, Self.minTextSize), Self.maxTextSize), forKey: "textSize")
            notify()
        }
    }
    public var lineWidth: LineWidth {
        get { LineWidth(rawValue: d.string(forKey: "lineWidth") ?? "") ?? .comfortable }
        set { d.set(newValue.rawValue, forKey: "lineWidth"); notify() }
    }
    public var density: Density {
        get { Density(rawValue: d.string(forKey: "density") ?? "") ?? .airy }
        set { d.set(newValue.rawValue, forKey: "density"); notify() }
    }
    public var renderEquations: Bool {
        get { d.object(forKey: "renderEquations") as? Bool ?? true }
        set { d.set(newValue, forKey: "renderEquations"); notify() }
    }
    public var renderDiagrams: Bool {
        get { d.object(forKey: "renderDiagrams") as? Bool ?? true }
        set { d.set(newValue, forKey: "renderDiagrams"); notify() }
    }
    /// Lay the document out as two columns side by side when the window is wide enough.
    ///
    /// On by default: at a comfortable measure a wide window shows a 500pt column of text in
    /// 1800pt of space, and the second column costs nothing but the gutter.
    public var spreadLayout: Bool {
        get { d.object(forKey: "spreadLayout") as? Bool ?? true }
        set { d.set(newValue, forKey: "spreadLayout"); notify() }
    }

    public var showFrontmatter: Bool {
        get { d.object(forKey: "showFrontmatter") as? Bool ?? true }
        set { d.set(newValue, forKey: "showFrontmatter"); notify() }
    }
    /// Off by default: a local-file reader that silently fetches remote images is a privacy
    /// surprise. Documents referencing `https://` images show a placeholder with the host
    /// name and an explicit Load button instead.
    public var loadRemoteImages: Bool {
        get { d.object(forKey: "loadRemoteImages") as? Bool ?? false }
        set { d.set(newValue, forKey: "loadRemoteImages"); notify() }
    }

    // MARK: Recents

    public struct Recent: Codable {
        public let path: String
        public let date: Date
    }

    public var recents: [Recent] {
        get {
            guard let data = d.data(forKey: "recents") else { return [] }
            return (try? JSONDecoder().decode([Recent].self, from: data)) ?? []
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "recents") }
    }

    public func noteRecent(_ url: URL) {
        var r = recents.filter { $0.path != url.path }
        r.insert(Recent(path: url.path, date: Date()), at: 0)
        recents = Array(r.prefix(10))
    }

    /// Folio is a dark-only app, so the appearance is pinned rather than followed.
    ///
    /// Worth being explicit that this diverges from the HIG, which asks apps to respect the
    /// systemwide appearance choice. Every color still goes through the semantic palette, so
    /// restoring light support later is a matter of removing this pin.
    public func applyTheme() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
