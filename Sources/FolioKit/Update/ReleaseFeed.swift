import Foundation

/// Where Folio's releases live. One constant rather than a setting: an updater pointed at a
/// URL a document could change would be a way to install an arbitrary app.
public enum UpdateSource {
    public static let owner = "huylg"
    public static let repository = "folio"

    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    }

    public static var releasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    /// Hosts an asset download is allowed to come from. GitHub serves release assets from its
    /// object storage by redirect, so both have to be here — but nothing else does, and a
    /// redirect that leaves them is a failure rather than something to follow.
    public static let allowedAssetHosts: Set<String> = [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    public static func isAllowedAssetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return allowedAssetHosts.contains(host)
    }

    /// The image the release workflow publishes.
    ///
    /// Both extensions, because the releases page holds both: the workflow ships a `.dmg` now, and
    /// everything up to v1.3.0 is a `.zip`. A reader on an old build is updating *from* that era,
    /// so refusing the older shape would leave exactly the people who most need the update unable
    /// to take it.
    static func isAppArchive(_ name: String) -> Bool {
        name.hasPrefix("Folio-") && (name.hasSuffix(".dmg") || name.hasSuffix(".zip"))
    }
}

/// A published release, reduced to what the updater needs.
///
/// `Codable` so a found-but-not-yet-installed update survives a quit: see
/// `AppSettings.pendingUpdate`.
public struct Release: Equatable, Codable, Sendable {
    public let version: AppVersion
    public let tag: String
    public let notes: String
    public let publishedAt: Date?
    public let assetURL: URL
    public let assetName: String
    public let byteCount: Int64
    /// The `.sha256` sidecar, when the release carries one. Older releases predate it.
    public let checksumURL: URL?
    public let pageURL: URL

    public init(version: AppVersion, tag: String, notes: String, publishedAt: Date?,
                assetURL: URL, assetName: String, byteCount: Int64,
                checksumURL: URL?, pageURL: URL) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.publishedAt = publishedAt
        self.assetURL = assetURL
        self.assetName = assetName
        self.byteCount = byteCount
        self.checksumURL = checksumURL
        self.pageURL = pageURL
    }
}

public enum UpdateError: Error, Equatable {
    case network(String)
    case badResponse(Int)
    case malformedFeed
    /// A release with no `Folio-*.zip`, or one whose asset URL is not a host we will download from.
    case noUsableAsset
    case unknownRunningVersion
    case notAnInstalledApp
    case downloadFailed(String)
    case checksumMismatch
    case corruptArchive(String)
    /// The extracted bundle is not the app it claims to be.
    case notFolio(String)
    case notWritable(String)
    case installFailed(String)

    public var message: String {
        switch self {
        case .network(let detail):
            return "Could not reach GitHub. \(detail)"
        case .badResponse(let code):
            return "GitHub answered with status \(code)."
        case .malformedFeed:
            return "GitHub's answer was not in the expected shape."
        case .noUsableAsset:
            return "The latest release has no Folio app archive to download."
        case .unknownRunningVersion:
            return "This build does not report a version, so there is nothing to compare against."
        case .notAnInstalledApp:
            return "Updating works on an installed Folio.app, not on a build run from the source tree."
        case .downloadFailed(let detail):
            return "The download did not finish. \(detail)"
        case .checksumMismatch:
            return "The download did not match its published checksum and was discarded."
        case .corruptArchive(let detail):
            return "The download could not be unpacked. \(detail)"
        case .notFolio(let detail):
            return "The download is not a valid Folio app. \(detail)"
        case .notWritable(let path):
            return "Folio cannot replace itself in \(path). Move the new copy in by hand."
        case .installFailed(let detail):
            return "The update could not be installed. \(detail)"
        }
    }
}

/// The check, behind a protocol so the controller's decisions can be tested without a network.
public protocol ReleaseFeed: AnyObject {
    func latest(completion: @escaping (Result<Release, UpdateError>) -> Void)
}

/// Reads `releases/latest` from GitHub's REST API.
///
/// `releases/latest` rather than the tag list on purpose: GitHub excludes drafts and pre-releases
/// from it, so neither can reach a reader by accident.
public final class GitHubReleaseFeed: ReleaseFeed {

    private let url: URL
    private let session: URLSession

    public init(url: URL = UpdateSource.latestReleaseURL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func latest(completion: @escaping (Result<Release, UpdateError>) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Folio", forHTTPHeaderField: "User-Agent")
        // The answer changes when a release is cut, not on a schedule a cache would know about,
        // and a stale hit here means telling the reader they are current when they are not.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(.badResponse(http.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(.malformedFeed))
                return
            }
            completion(Self.decode(data))
        }.resume()
    }

    // MARK: Decoding

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browser_download_url: String
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let published_at: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Exposed to the tests, which run it against a checked-in copy of a real GitHub answer.
    static func decode(_ data: Data) -> Result<Release, UpdateError> {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .failure(.malformedFeed)
        }
        guard payload.draft != true, payload.prerelease != true else {
            return .failure(.noUsableAsset)
        }
        guard let version = AppVersion(payload.tag_name) else {
            return .failure(.malformedFeed)
        }
        guard let page = URL(string: payload.html_url) else {
            return .failure(.malformedFeed)
        }

        // The disk image wins when a release carries both, since that is what the workflow builds
        // and what the install instructions describe.
        let archives = payload.assets.filter { UpdateSource.isAppArchive($0.name) }
        guard let archive = archives.first(where: { $0.name.hasSuffix(".dmg") }) ?? archives.first,
              let assetURL = URL(string: archive.browser_download_url),
              UpdateSource.isAllowedAssetURL(assetURL)
        else {
            return .failure(.noUsableAsset)
        }

        let checksum = payload.assets
            .first { $0.name == archive.name + ".sha256" }
            .flatMap { URL(string: $0.browser_download_url) }
            .flatMap { UpdateSource.isAllowedAssetURL($0) ? $0 : nil }

        return .success(Release(
            version: version,
            tag: payload.tag_name,
            notes: payload.body ?? "",
            publishedAt: payload.published_at.flatMap(Self.date(from:)),
            assetURL: assetURL,
            assetName: archive.name,
            byteCount: archive.size,
            checksumURL: checksum,
            pageURL: page
        ))
    }

    private static let timestamps: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func date(from raw: String) -> Date? { timestamps.date(from: raw) }
}
