import Foundation

/// Presentation metadata only. Sparkle owns version comparison and archive validation.
public struct Release: Equatable {
    public let version: String
    public let pageURL: URL
}

public enum UpdateSource {
    public static let releasesPageURL = URL(string: "https://github.com/huylg/folio/releases")!
}

public enum UpdateError: Error, Equatable {
    case notAnInstalledApp
    case configuration(String)
    case updater(String)

    public var message: String {
        switch self {
        case .updater(let detail), .configuration(let detail): return detail
        case .notAnInstalledApp:
            return "Updating requires a packaged Folio.app."
        }
    }
}
