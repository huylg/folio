import AppKit

extension Notification.Name {
    public static let folioSettingsChanged = Notification.Name("folioSettingsChanged")
}

/// UserDefaults-backed app settings. Folio is a read-only viewer: these preferences and the
/// recents list are the only things it ever persists.
public final class AppSettings {
    public static let shared = AppSettings()
    private let d: UserDefaults

    /// Injectable so a test can exercise a stored value — the `columnLayout` migration, say —
    /// in a scratch suite instead of the domain every other test shares.
    init(defaults: UserDefaults = .standard) { d = defaults }

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

    /// How many columns the reading pane may use: as many as fit, or a count the reader pinned.
    ///
    /// Automatic has no ceiling. A column is always a full reading measure, so the width is the
    /// only thing that can add one — there is no point at which the app knows better than the
    /// display in front of the reader. Anyone who finds a wide page too far to cross pins a
    /// smaller count instead, which is what the choice is for.
    ///
    /// A pinned count is still a ceiling rather than a promise: three asked for on a pane that
    /// holds two gives two, not three narrow ones.
    ///
    /// Stored as an `Int` — 0 for automatic, otherwise the count — so a struct rather than an
    /// enum, which would have to name every count it allows and thereby cap it.
    public struct ColumnLayout: Equatable {
        /// 0 for automatic, otherwise the pinned number of columns.
        public let rawValue: Int

        public init(rawValue: Int) { self.rawValue = max(0, rawValue) }

        public static let automatic = ColumnLayout(rawValue: 0)
        public static func fixed(_ columns: Int) -> ColumnLayout {
            ColumnLayout(rawValue: max(1, columns))
        }

        /// Named for readability where a count is spelled out.
        public static let one = ColumnLayout.fixed(1)
        public static let two = ColumnLayout.fixed(2)
        public static let three = ColumnLayout.fixed(3)

        public var isAutomatic: Bool { rawValue == 0 }

        /// The most columns this choice allows. Automatic is bounded by the pane alone.
        public var limit: Int { isAutomatic ? .max : rawValue }

        /// The choices offered in the menu and in Settings.
        ///
        /// Where the list stops is a question about shortcuts and controls, not about layout: a
        /// larger count stored by hand is honoured, and automatic reaches whatever the display
        /// holds regardless.
        public static let offered: [ColumnLayout] =
            [.automatic] + (1...4).map(ColumnLayout.fixed)

        public var displayName: String {
            guard !isAutomatic else { return "Automatic" }
            let spelled = [1: "One", 2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six"]
            return spelled[rawValue] ?? "\(rawValue)"
        }
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
    /// How many columns the reading pane may use.
    ///
    /// Automatic by default: at a comfortable measure a wide window shows a 500pt column of
    /// text in 1800pt of space, and each further column costs nothing but the gutter.
    public var columnLayout: ColumnLayout {
        get {
            if let raw = d.object(forKey: "columnLayout") as? Int {
                return ColumnLayout(rawValue: raw)
            }
            // Migrated from `spreadLayout`, the Bool this replaced: off meant one column, on
            // meant "two when it fits", which is what automatic now says with more headroom.
            // Read through rather than rewritten on launch — nothing needs the old key gone,
            // and a getter that migrates can be tested without touching disk.
            if let legacy = d.object(forKey: "spreadLayout") as? Bool {
                return legacy ? .automatic : .one
            }
            return .automatic
        }
        set { d.set(newValue.rawValue, forKey: "columnLayout"); notify() }
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

    // MARK: Updates

    /// Whether Folio may check GitHub for a new release on its own.
    ///
    /// Optional on purpose: "not yet asked" is a third state, and it is the one a fresh install is
    /// in. Folio otherwise never touches the network without being told to — remote images are off
    /// by default for exactly this reason — so an updater that started polling on first launch
    /// would contradict what the app tells the reader two panes away. It asks once instead, and
    /// `Check for Updates…` works regardless of the answer.
    public var automaticUpdateChecks: Bool? {
        get { d.object(forKey: "automaticUpdateChecks") as? Bool }
        set {
            if let newValue {
                d.set(newValue, forKey: "automaticUpdateChecks")
            } else {
                d.removeObject(forKey: "automaticUpdateChecks")
            }
            notify()
        }
    }

    /// When the last automatic check ran, so launching four windows in a morning is still one
    /// request. A manual check ignores this.
    public var lastUpdateCheck: Date? {
        get { d.object(forKey: "lastUpdateCheck") as? Date }
        set { d.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// An update that has been found but not yet installed.
    ///
    /// Remembered across launches, because otherwise it is forgotten the moment the app quits and
    /// the once-a-day throttle then stops it being found again — so a reader who saw the pill on
    /// Monday morning, quit, and came back after lunch would see nothing at all, and would go on
    /// seeing nothing until the throttle expired. Stored as the whole release rather than a
    /// version string so restoring it needs no network.
    public var pendingUpdate: Release? {
        get {
            guard let data = d.data(forKey: "pendingUpdate") else { return nil }
            return try? JSONDecoder().decode(Release.self, from: data)
        }
        set {
            if let newValue {
                d.set(try? JSONEncoder().encode(newValue), forKey: "pendingUpdate")
            } else {
                d.removeObject(forKey: "pendingUpdate")
            }
        }
    }

    /// A version the reader asked not to be told about again. Stored as the string rather than a
    /// parsed version so an unreadable value can only ever fail to match.
    public var skippedVersion: String? {
        get { d.string(forKey: "skippedVersion") }
        set {
            if let newValue {
                d.set(newValue, forKey: "skippedVersion")
            } else {
                d.removeObject(forKey: "skippedVersion")
            }
            notify()
        }
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
