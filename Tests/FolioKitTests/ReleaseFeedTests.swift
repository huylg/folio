import XCTest
@testable import FolioKit

/// Decoding GitHub's `releases/latest` answer, and refusing the ones we should not act on.
///
/// The fixture is the shape of a real answer rather than the minimum the decoder needs, so a field
/// GitHub renames is a failing test rather than a silent nil. The host and scheme assertions are
/// the ones with teeth: this decoder produces the URL the app will download an executable from.
final class ReleaseFeedTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: "json"),
                                "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    private func decoded(_ name: String = "github-release") throws -> Release {
        switch GitHubReleaseFeed.decode(try fixture(name)) {
        case .success(let release): return release
        case .failure(let error): throw XCTSkip("decode failed: \(error)")
        }
    }

    func testReadsARealAnswer() throws {
        let release = try decoded()
        XCTAssertEqual(release.version, AppVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(release.tag, "v1.4.0")
        XCTAssertEqual(release.assetName, "Folio-v1.4.0.dmg")
        XCTAssertEqual(release.byteCount, 4_318_842)
        XCTAssertEqual(release.pageURL.absoluteString,
                       "https://github.com/huylg/folio/releases/tag/v1.4.0")
        XCTAssertTrue(release.notes.contains("Document-wide find"))
        XCTAssertNotNil(release.publishedAt)
    }

    /// The image, not the checksum beside it — the two names differ by a suffix, and picking the
    /// wrong one would download 65 bytes and call it an app. And the `.dmg` over the `.zip` when a
    /// release carries both, since the image is what the workflow builds.
    func testPicksTheDiskImageAndItsChecksum() throws {
        let release = try decoded()
        XCTAssertEqual(release.assetURL.lastPathComponent, "Folio-v1.4.0.dmg")
        XCTAssertEqual(release.checksumURL?.lastPathComponent, "Folio-v1.4.0.dmg.sha256")
    }

    /// Everything up to v1.3.0 was published as a zip. A reader on one of those builds is updating
    /// out of exactly that era, so a zip-only release still has to be usable.
    func testAZipOnlyReleaseIsStillAccepted() {
        let json = """
        {"tag_name":"v1.3.0","html_url":"https://github.com/huylg/folio/releases/tag/v1.3.0",
         "assets":[{"name":"Folio-v1.3.0.zip","size":4000000,
                    "browser_download_url":"https://github.com/huylg/folio/x/Folio-v1.3.0.zip"}]}
        """
        switch GitHubReleaseFeed.decode(Data(json.utf8)) {
        case .failure(let error):
            XCTFail("a zip release should still be usable: \(error)")
        case .success(let release):
            XCTAssertEqual(release.assetName, "Folio-v1.3.0.zip")
            XCTAssertNil(release.checksumURL, "older releases carry no checksum")
        }
    }

    func testARelaseWithNoAppArchiveIsRefused() {
        let json = """
        {"tag_name":"v1.4.0","html_url":"https://github.com/huylg/folio/releases/tag/v1.4.0",
         "assets":[{"name":"notes.txt","size":10,
                    "browser_download_url":"https://github.com/huylg/folio/x/notes.txt"}]}
        """
        XCTAssertEqual(GitHubReleaseFeed.decode(Data(json.utf8)), .failure(.noUsableAsset))
    }

    /// A release the maintainer has not finished, or one marked pre-release, must not be offered.
    /// `releases/latest` already excludes both; this asserts we would refuse them anyway rather
    /// than trusting the endpoint to keep doing it.
    func testDraftsAndPrereleasesAreRefused() {
        for flag in ["\"draft\":true", "\"prerelease\":true"] {
            let json = """
            {"tag_name":"v1.4.0","html_url":"https://github.com/huylg/folio/releases/tag/v1.4.0",
             \(flag),
             "assets":[{"name":"Folio-v1.4.0.zip","size":10,
                        "browser_download_url":"https://github.com/huylg/folio/x/Folio-v1.4.0.zip"}]}
            """
            XCTAssertEqual(GitHubReleaseFeed.decode(Data(json.utf8)), .failure(.noUsableAsset),
                           "\(flag) should not be offered")
        }
    }

    /// The assertion this whole file exists for: the app downloads and runs whatever this URL
    /// points at, so plain HTTP and any host outside GitHub are refused outright rather than
    /// followed and checked later.
    func testAnAssetOffHTTPSOrOffGitHubIsRefused() {
        let hostile = [
            "http://github.com/huylg/folio/releases/download/v1.4.0/Folio-v1.4.0.zip",
            "https://githubb.com/huylg/folio/releases/download/v1.4.0/Folio-v1.4.0.zip",
            "https://github.com.example.net/huylg/folio/Folio-v1.4.0.zip",
            "file:///tmp/Folio-v1.4.0.zip",
        ]
        for url in hostile {
            let json = """
            {"tag_name":"v1.4.0","html_url":"https://github.com/huylg/folio/releases/tag/v1.4.0",
             "assets":[{"name":"Folio-v1.4.0.zip","size":10,"browser_download_url":"\(url)"}]}
            """
            XCTAssertEqual(GitHubReleaseFeed.decode(Data(json.utf8)), .failure(.noUsableAsset),
                           "\(url) should be refused")
        }
    }

    func testTheHostsWeDoAcceptAreTheOnesGitHubRedirectsTo() {
        for host in ["github.com", "objects.githubusercontent.com",
                     "release-assets.githubusercontent.com"] {
            let url = URL(string: "https://\(host)/x/Folio-v1.4.0.zip")!
            XCTAssertTrue(UpdateSource.isAllowedAssetURL(url), "\(host) should be allowed")
        }
    }

    func testAMalformedTagIsRefusedRatherThanGuessedAt() {
        let json = """
        {"tag_name":"nightly","html_url":"https://github.com/huylg/folio/releases/tag/nightly",
         "assets":[{"name":"Folio-nightly.zip","size":10,
                    "browser_download_url":"https://github.com/huylg/folio/x/Folio-nightly.zip"}]}
        """
        XCTAssertEqual(GitHubReleaseFeed.decode(Data(json.utf8)), .failure(.malformedFeed))
    }

    func testGarbageIsNotAFeed() {
        XCTAssertEqual(GitHubReleaseFeed.decode(Data("not json".utf8)), .failure(.malformedFeed))
        XCTAssertEqual(GitHubReleaseFeed.decode(Data()), .failure(.malformedFeed))
    }
}
