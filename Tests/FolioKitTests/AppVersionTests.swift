import XCTest
@testable import FolioKit

/// The version parser and its ordering.
///
/// Worth pinning on its own because the two sides of an update check come from different places —
/// a plist the Makefile stamps and a tag typed by hand — and every decision the updater makes
/// rests on one comparison. A parser that quietly returned nil for `v1.3.0` would leave the app
/// convinced it was current forever.
final class AppVersionTests: XCTestCase {

    func testParsesTheShapesTheTwoSidesActuallyUse() {
        XCTAssertEqual(AppVersion("1.2.3"), AppVersion(major: 1, minor: 2, patch: 3))
        // The tags in this repository carry the prefix; the plist does not.
        XCTAssertEqual(AppVersion("v1.2.3"), AppVersion(major: 1, minor: 2, patch: 3))
        // The Info.plist template ships "1.0", with no patch field at all.
        XCTAssertEqual(AppVersion("1.0"), AppVersion(major: 1, minor: 0, patch: 0))
        XCTAssertEqual(AppVersion("2"), AppVersion(major: 2, minor: 0, patch: 0))
    }

    func testKeepsAPrereleaseAndDropsBuildMetadata() {
        XCTAssertEqual(AppVersion("1.4.0-beta.2"),
                       AppVersion(major: 1, minor: 4, patch: 0, prerelease: "beta.2"))
        XCTAssertTrue(AppVersion("1.4.0-beta.2")!.isPrerelease)
        // Semver: build metadata takes no part in precedence, so it is not kept.
        XCTAssertEqual(AppVersion("1.4.0+abc123"), AppVersion(major: 1, minor: 4, patch: 0))
        XCTAssertFalse(AppVersion("1.4.0")!.isPrerelease)
    }

    func testRefusesWhatItCannotUnderstand() {
        for raw in ["", "latest", "1.2.3.4", "1.x", "-1.0", "1..0", "v", "nightly-2026-08-24"] {
            XCTAssertNil(AppVersion(raw), "\"\(raw)\" should not parse")
        }
    }

    func testOrdersByEachFieldInTurn() {
        XCTAssertLessThan(AppVersion("1.0.0")!, AppVersion("1.0.1")!)
        XCTAssertLessThan(AppVersion("1.0.9")!, AppVersion("1.1.0")!)
        XCTAssertLessThan(AppVersion("1.9.9")!, AppVersion("2.0.0")!)
        // Not a string comparison: "10" sorts before "9" as text and after it as a number.
        XCTAssertLessThan(AppVersion("1.9.0")!, AppVersion("1.10.0")!)
        XCTAssertEqual(AppVersion("1.3.0")!, AppVersion("v1.3.0")!)
    }

    func testAPrereleaseComesBeforeTheReleaseItLeadsTo() {
        XCTAssertLessThan(AppVersion("1.4.0-beta.1")!, AppVersion("1.4.0")!)
        XCTAssertLessThan(AppVersion("1.4.0-beta.1")!, AppVersion("1.4.0-beta.2")!)
        XCTAssertLessThan(AppVersion("1.3.0")!, AppVersion("1.4.0-beta.1")!)
    }

    func testDescriptionRoundTrips() {
        for raw in ["1.2.3", "1.0.0", "1.4.0-beta.2", "12.0.7"] {
            let version = AppVersion(raw)!
            XCTAssertEqual(version.description, raw)
            XCTAssertEqual(AppVersion(version.description), version)
        }
    }

    /// The two states Settings has to render, exercised against plist values rather than the
    /// xctest runner's own version, which is whatever Xcode decided that week.
    func testSummaryReportsAVersionOrSaysItHasNone() {
        XCTAssertEqual(
            AppVersion.summary(info: ["CFBundleShortVersionString": "1.3.0",
                                      "CFBundleVersion": "87"]),
            "1.3.0 (build 87)")
        XCTAssertEqual(
            AppVersion.summary(info: ["CFBundleShortVersionString": "1.3.0"]),
            "1.3.0")
        XCTAssertEqual(AppVersion.summary(info: ["CFBundleVersion": "87"]),
                       "Unversioned build")
        // The stamp failing open is the case that matters: a plist left holding the template's
        // "1.0" is a version, and would be compared as one.
        XCTAssertEqual(AppVersion.from(info: ["CFBundleShortVersionString": "1.0"]),
                       AppVersion(major: 1, minor: 0))
    }

    func testABundleThatNamesNoVersionParsesToNothing() {
        // Which is the state `swift test` runs in, and what keeps the suite off the network.
        XCTAssertNil(AppVersion.from(info: [:]))
        XCTAssertNil(AppVersion.from(info: ["CFBundleShortVersionString": "unknown"]))
    }
}
