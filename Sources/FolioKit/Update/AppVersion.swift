import Foundation

/// A released version of the app, as it appears in a bundle's `CFBundleShortVersionString` and in
/// a GitHub tag.
///
/// Deliberately forgiving about what it will parse and deliberately strict about what it will
/// compare. The two sides of an update check come from different places — a plist written by the
/// Makefile and a tag typed by hand — and a comparison that returned `false` for a version it
/// failed to understand would silently pin the app to whatever it is running.
public struct AppVersion: Comparable, Hashable, Codable, CustomStringConvertible, Sendable {

    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Everything after `-`: `beta.2` in `1.4.0-beta.2`. Empty for a plain release.
    ///
    /// Kept as a string rather than parsed into identifiers. Ordering only ever needs to answer
    /// "is this a pre-release of the same numbers", and Folio has never published one — a full
    /// semver precedence implementation would be code with no caller.
    public let prerelease: String

    public init(major: Int, minor: Int, patch: Int = 0, prerelease: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `1.2.3`, `v1.2.3`, `1.2`, `1`, and `1.4.0-beta.2`.
    ///
    /// Returns nil rather than guessing at anything else. A build metadata suffix (`+abc`) is
    /// dropped, which is what semver says to do: it takes no part in precedence.
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[text.startIndex..<plus]) }

        let prerelease: String
        if let dash = text.firstIndex(of: "-") {
            prerelease = String(text[text.index(after: dash)...])
            text = String(text[text.startIndex..<dash])
        } else {
            prerelease = ""
        }

        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        let numbers = fields.map { Int($0) }
        guard !numbers.contains(where: { $0 == nil || $0! < 0 }) else { return nil }

        self.init(major: numbers[0]!,
                  minor: numbers.count > 1 ? numbers[1]! : 0,
                  patch: numbers.count > 2 ? numbers[2]! : 0,
                  prerelease: prerelease)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return isPrerelease ? "\(core)-\(prerelease)" : core
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // Same numbers: a pre-release comes before the release it leads to, and two pre-releases
        // fall back to lexicographic order.
        if a.prerelease == b.prerelease { return false }
        if a.isPrerelease && !b.isPrerelease { return true }
        if !a.isPrerelease && b.isPrerelease { return false }
        return a.prerelease < b.prerelease
    }
}

// MARK: - The running app

extension AppVersion {

    /// What the running bundle says it is, or nil if it says something unparseable.
    ///
    /// Nil under `swift test`, where `Bundle.main` is the xctest runner rather than Folio. That is
    /// the honest answer and the updater treats it as one: a build that cannot name its own
    /// version has no business deciding it is out of date.
    public static var current: AppVersion? { fromBundle(.main) }

    public static func fromBundle(_ bundle: Bundle) -> AppVersion? {
        from(info: bundle.infoDictionary ?? [:])
    }

    /// The primitive the two above are built on. Takes the dictionary rather than the bundle so a
    /// test can hand it the plist values it wants to see handled — `Bundle` cannot usefully be
    /// subclassed, and the version the xctest runner reports is nobody's business.
    public static func from(info: [String: Any]) -> AppVersion? {
        guard let raw = info["CFBundleShortVersionString"] as? String else { return nil }
        return AppVersion(raw)
    }

    /// `CFBundleVersion` — the commit count the Makefile stamps. Shown beside the version in
    /// Settings, never compared: it is a build ordinal, not a release.
    public static func buildNumber(info: [String: Any]) -> String? {
        info["CFBundleVersion"] as? String
    }

    /// `1.3.0 (build 87)` for Settings, and an honest admission when the bundle does not say.
    /// A build run from the source tree genuinely has no version, and saying so is more use to
    /// whoever is looking than printing the template's 1.0.
    public static func summary(info: [String: Any]) -> String {
        guard let version = from(info: info) else { return "Unversioned build" }
        guard let build = buildNumber(info: info) else { return "\(version)" }
        return "\(version) (build \(build))"
    }

    public static func summary(for bundle: Bundle = .main) -> String {
        summary(info: bundle.infoDictionary ?? [:])
    }
}
