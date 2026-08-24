import XCTest
@testable import FolioKit

/// What the installer will and will not unpack over the running app.
///
/// These build a real bundle, archive it with the same `ditto` the release workflow uses, and run
/// the real verification over it. The point is the refusals: this is the one code path in Folio
/// that takes bytes off the network and puts them somewhere macOS will execute them, so an
/// archive that is not a Folio must not get that far. The swap itself is not exercised — it
/// replaces the running app by design — but the script it writes is.
final class UpdateInstallerTests: XCTestCase {

    // MARK: Fixtures

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A bundle with the parts the validator looks at: an executable that is actually executable,
    /// and an Info.plist that names an identifier and a version.
    private func makeBundle(in directory: URL,
                            named name: String = "Folio.app",
                            identifier: String = UpdateInstaller.expectedBundleIdentifier,
                            version: String? = "1.4.0",
                            executable: Bool = true) throws -> URL {
        let bundle = directory.appendingPathComponent(name, isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let binary = macOS.appendingPathComponent("Folio")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                              ofItemAtPath: binary.path)

        var info: [String: Any] = ["CFBundleIdentifier": identifier,
                                   "CFBundleExecutable": "Folio",
                                   "CFBundleName": "Folio"]
        if let version { info["CFBundleShortVersionString"] = version }
        try (info as NSDictionary).write(
            to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    /// `ditto -c -k --keepParent`, as the releases up to v1.3.0 were archived.
    private func archive(_ bundle: URL, in directory: URL) throws -> URL {
        let zip = directory.appendingPathComponent("Folio-v1.4.0.zip")
        let result = UpdateInstaller.run(
            "/usr/bin/ditto", ["-c", "-k", "--keepParent", bundle.path, zip.path])
        XCTAssertEqual(result.status, 0, "ditto failed: \(result.errorText)")
        return zip
    }

    /// A disk image built the way `make dmg` builds one: the app beside a symlink to
    /// `/Applications`, compressed with `hdiutil -format UDZO`.
    private func diskImage(_ bundle: URL, in directory: URL) throws -> URL {
        let root = try scratch().appendingPathComponent("dmgroot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: bundle, to: root.appendingPathComponent(bundle.lastPathComponent))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Applications"),
            withDestinationURL: URL(fileURLWithPath: "/Applications"))

        let dmg = directory.appendingPathComponent("Folio-v1.4.0.dmg")
        let result = UpdateInstaller.run("/usr/bin/hdiutil", [
            "create", "-volname", "Folio", "-srcfolder", root.path,
            "-ov", "-format", "UDZO", "-quiet", dmg.path,
        ])
        try XCTSkipUnless(result.status == 0, "hdiutil create failed: \(result.errorText)")
        return dmg
    }

    /// No checksum URL, so `verifyAndUnpack` does the unpack and the validation without a network.
    private func release(version: String = "1.4.0", bytes: Int64 = 0) -> Release {
        Release(version: AppVersion(version)!,
                tag: "v\(version)",
                notes: "",
                publishedAt: nil,
                assetURL: URL(string: "https://github.com/huylg/folio/x/Folio-v\(version).zip")!,
                assetName: "Folio-v\(version).zip",
                byteCount: bytes,
                checksumURL: nil,
                pageURL: URL(string: "https://github.com/huylg/folio/releases/tag/v\(version)")!)
    }

    // MARK: The happy path — a disk image

    /// The shape the release workflow actually publishes now. A `.dmg` has to be mounted rather
    /// than extracted, so this is a different code path from the zip below, not a variation on it.
    func testAGoodDiskImageMountsAndValidates() throws {
        let root = try scratch()
        let source = try makeBundle(in: try scratch())
        let dmg = try diskImage(source, in: root)

        switch UpdateInstaller.verifyAndUnpack(archive: dmg, release: release(), in: root) {
        case .failure(let error):
            XCTFail("a good disk image was refused: \(error.message)")
        case .success(let bundle):
            XCTAssertEqual(bundle.lastPathComponent, "Folio.app")
            XCTAssertNil(UpdateInstaller.validate(bundleAt: bundle))
            XCTAssertTrue(FileManager.default.isExecutableFile(
                atPath: bundle.appendingPathComponent("Contents/MacOS/Folio").path))
            // Copied off the image, not left pointing into a mounted volume that is about to go
            // away — an installer handing back a path on an unmounted disk would fail later, far
            // from the cause.
            XCTAssertTrue(bundle.path.hasPrefix(root.path), "the app should be in the scratch dir")
            XCTAssertFalse(bundle.path.contains("/Volumes/"))
        }
    }

    /// The image must not be left mounted, whether the copy worked or not — a stranded volume is
    /// something the reader has to eject by hand.
    func testTheImageIsUnmountedAfterwards() throws {
        let root = try scratch()
        let dmg = try diskImage(try makeBundle(in: try scratch()), in: root)
        let mountPoint = root.appendingPathComponent("mount")

        _ = UpdateInstaller.verifyAndUnpack(archive: dmg, release: release(), in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint.path),
                       "the mount point should have been detached and removed")
        let attached = UpdateInstaller.run("/usr/bin/hdiutil", ["info"])
        XCTAssertFalse(attached.outputText.contains(root.path),
                       "the image should not still be attached")
    }

    func testAnImageWithNoAppInsideIsRefused() throws {
        let root = try scratch()
        let empty = try scratch().appendingPathComponent("dmgroot", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try "hello".write(to: empty.appendingPathComponent("README.txt"),
                          atomically: true, encoding: .utf8)
        let dmg = root.appendingPathComponent("Folio-v1.4.0.dmg")
        let made = UpdateInstaller.run("/usr/bin/hdiutil", [
            "create", "-volname", "Folio", "-srcfolder", empty.path,
            "-ov", "-format", "UDZO", "-quiet", dmg.path,
        ])
        try XCTSkipUnless(made.status == 0, "hdiutil create failed: \(made.errorText)")

        let result = UpdateInstaller.verifyAndUnpack(archive: dmg, release: release(), in: root)
        guard case .failure(.notFolio) = result else {
            return XCTFail("an image with no app in it should be refused, got \(result)")
        }
    }

    func testAFileThatIsNotADiskImageIsRefused() throws {
        let root = try scratch()
        let dmg = root.appendingPathComponent("Folio-v1.4.0.dmg")
        try Data(repeating: 0x41, count: 4096).write(to: dmg)

        let result = UpdateInstaller.verifyAndUnpack(archive: dmg, release: release(), in: root)
        guard case .failure(.corruptArchive(let reason)) = result else {
            return XCTFail("garbage should not mount, got \(result)")
        }
        // hdiutil's own words rather than the fallback: a mount that fails with nothing to say
        // leaves the reader, and a CI log, with nothing to act on.
        XCTAssertNotEqual(reason, "The disk image would not mount.",
                          "the refusal should carry the reason hdiutil gave")
    }

    // MARK: The happy path — a zip

    /// Everything up to v1.3.0 shipped as a zip, and a reader updating away from one of those
    /// builds is downloading whatever that release carried.
    func testAGoodZipArchiveUnpacksAndValidates() throws {
        let root = try scratch()
        let source = try makeBundle(in: try scratch())
        let zip = try archive(source, in: root)

        switch UpdateInstaller.verifyAndUnpack(archive: zip, release: release(), in: root) {
        case .failure(let error):
            XCTFail("a good archive was refused: \(error.message)")
        case .success(let bundle):
            XCTAssertEqual(bundle.lastPathComponent, "Folio.app")
            XCTAssertNil(UpdateInstaller.validate(bundleAt: bundle))
            // The executable bit surviving the round trip is the reason this uses ditto rather
            // than unzip, so assert it rather than assuming.
            XCTAssertTrue(FileManager.default.isExecutableFile(
                atPath: bundle.appendingPathComponent("Contents/MacOS/Folio").path))
        }
    }

    // MARK: Refusals

    func testAZipWithNoAppInsideIsRefused() throws {
        let root = try scratch()
        let loose = try scratch().appendingPathComponent("notes.txt")
        try "hello".write(to: loose, atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("Folio-v1.4.0.zip")
        _ = UpdateInstaller.run("/usr/bin/ditto",
                                ["-c", "-k", "--keepParent", loose.path, zip.path])

        let result = UpdateInstaller.verifyAndUnpack(archive: zip, release: release(), in: root)
        guard case .failure(.notFolio) = result else {
            return XCTFail("an archive with no app in it should be refused, got \(result)")
        }
    }

    func testACorruptZipIsRefused() throws {
        let root = try scratch()
        let zip = root.appendingPathComponent("Folio-v1.4.0.zip")
        try Data(repeating: 0x41, count: 4096).write(to: zip)

        let result = UpdateInstaller.verifyAndUnpack(archive: zip, release: release(), in: root)
        guard case .failure(.corruptArchive) = result else {
            return XCTFail("garbage should not unpack, got \(result)")
        }
    }

    /// The assertion with the most teeth here: an app that is not Folio must not be installed as
    /// Folio, however well-formed its bundle is.
    func testABundleClaimingADifferentIdentifierIsRefused() throws {
        let bundle = try makeBundle(in: try scratch(), identifier: "com.example.something")
        let error = UpdateInstaller.validate(bundleAt: bundle)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.message.contains("com.example.something"),
                      "the reason should name what it found: \(error!.message)")
    }

    func testABundleWithNoVersionIsRefused() throws {
        let bundle = try makeBundle(in: try scratch(), version: nil)
        guard case .notFolio = UpdateInstaller.validate(bundleAt: bundle) else {
            return XCTFail("a bundle that does not say what it is should be refused")
        }
    }

    func testABundleWithNoRunnableExecutableIsRefused() throws {
        let bundle = try makeBundle(in: try scratch(), executable: false)
        guard case .notFolio = UpdateInstaller.validate(bundleAt: bundle) else {
            return XCTFail("a bundle whose executable will not run should be refused")
        }
    }

    func testSomethingThatIsNotABundleIsRefused() throws {
        let file = try scratch().appendingPathComponent("Folio.app")
        try "not a bundle".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotNil(UpdateInstaller.validate(bundleAt: file))

        let missing = try scratch().appendingPathComponent("Nothing.app")
        XCTAssertNotNil(UpdateInstaller.validate(bundleAt: missing))
    }

    /// A downgrade is refused when a floor is given — the download and the check happen at
    /// different moments, and the bundle inside the zip is the only thing that can be trusted
    /// about what version it actually is.
    func testABundleThatIsNotNewerIsRefusedAgainstAFloor() throws {
        let bundle = try makeBundle(in: try scratch(), version: "1.2.0")
        XCTAssertNil(UpdateInstaller.validate(bundleAt: bundle),
                     "with no floor, the version is not the validator's business")
        XCTAssertNotNil(UpdateInstaller.validate(bundleAt: bundle,
                                                 minimumVersion: AppVersion("1.3.0")!))
        XCTAssertNotNil(UpdateInstaller.validate(bundleAt: bundle,
                                                 minimumVersion: AppVersion("1.2.0")!),
                        "the same version is not newer")
        XCTAssertNil(UpdateInstaller.validate(bundleAt: bundle,
                                              minimumVersion: AppVersion("1.1.0")!))
    }

    // MARK: Checksums

    func testTheDigestMatchesShasum() throws {
        let file = try scratch().appendingPathComponent("payload.bin")
        try Data("the quick brown fox".utf8).write(to: file)

        // Compared against the system tool rather than a hardcoded digest, so this also catches
        // the streaming loop dropping or double-counting a chunk.
        XCTAssertEqual(UpdateInstaller.sha256(ofFileAt: file), try shasum(file))
    }

    private func shasum(_ file: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return try XCTUnwrap(UpdateInstaller.normalizeChecksum(text))
    }

    /// A digest larger than memory should not need to be in memory, and a multi-megabyte file is
    /// enough to exercise more than one pass of the 1 MB read loop.
    func testAFileLargerThanOneChunkHashesCorrectly() throws {
        let file = try scratch().appendingPathComponent("large.bin")
        try Data(repeating: 0x7A, count: 3 * (1 << 20) + 17).write(to: file)
        XCTAssertEqual(UpdateInstaller.sha256(ofFileAt: file), try shasum(file))
    }

    func testChecksumTextIsAcceptedInEitherShapeShasumProduces() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(UpdateInstaller.normalizeChecksum(digest), digest)
        XCTAssertEqual(UpdateInstaller.normalizeChecksum(digest + "\n"), digest)
        // `shasum -a 256 file` writes "<digest>  <filename>", which is what the workflow pipes
        // through awk — but an older release asset may carry the whole line.
        XCTAssertEqual(UpdateInstaller.normalizeChecksum("\(digest)  Folio-v1.4.0.zip\n"), digest)
        XCTAssertEqual(UpdateInstaller.normalizeChecksum(digest.uppercased()), digest)
    }

    func testChecksumTextThatIsNotADigestIsRejected() {
        for raw in ["", "\n", "not a digest", String(repeating: "a", count: 63),
                    String(repeating: "z", count: 64), "404: Not Found"] {
            XCTAssertNil(UpdateInstaller.normalizeChecksum(raw), "\"\(raw)\" is not a digest")
        }
    }

    func testAChecksumFetchedFromOffGitHubIsRefusedWithoutAsking() {
        let result = UpdateInstaller.downloadChecksum(
            from: URL(string: "http://example.com/Folio.zip.sha256")!)
        XCTAssertEqual(result, .failure(.noUsableAsset))
    }

    // MARK: The swap script

    /// A path with a space in it is the normal case on macOS, not the exotic one, and quoting it
    /// wrongly would make the script delete the wrong thing or nothing at all.
    func testTheScriptQuotesPathsThatNeedIt() {
        XCTAssertEqual(UpdateInstaller.shellQuoted("/Applications/Folio.app"),
                       "'/Applications/Folio.app'")
        XCTAssertEqual(UpdateInstaller.shellQuoted("/Users/a b/My Folio.app"),
                       "'/Users/a b/My Folio.app'")
        XCTAssertEqual(UpdateInstaller.shellQuoted("/Users/o'brien/Folio.app"),
                       "'/Users/o'\\''brien/Folio.app'")
    }

    /// The script is what runs after the app has quit, so nothing in the suite can observe it
    /// working. Read it instead: it must wait, back the old bundle up before removing it, restore
    /// it on failure, clear the quarantine flag, and relaunch.
    func testTheScriptBacksUpBeforeItReplacesAndRestoresOnFailure() {
        let script = UpdateInstaller.swapScript(
            replacement: URL(fileURLWithPath: "/tmp/new/Folio.app"),
            destination: URL(fileURLWithPath: "/Applications/Folio.app"))

        XCTAssertTrue(script.contains("kill -0"), "it must wait for the app to exit")
        XCTAssertTrue(script.contains("mv \"$dest\" \"$backup\""),
                      "the old bundle must be moved aside, not deleted")
        XCTAssertTrue(script.contains("mv \"$backup\" \"$dest\""),
                      "a failed copy must put the old bundle back")
        // Folio is ad-hoc signed: a quarantined relaunch is refused outright, not prompted.
        XCTAssertTrue(script.contains("com.apple.quarantine"))
        XCTAssertTrue(script.contains("/usr/bin/open"))
        XCTAssertTrue(script.contains("'/Applications/Folio.app'"))
    }

    /// A valid `sh` script, checked by the shell itself rather than by reading it.
    func testTheScriptParses() throws {
        let script = try scratch().appendingPathComponent("install.sh")
        try UpdateInstaller.swapScript(
            replacement: URL(fileURLWithPath: "/tmp/new/Folio.app"),
            destination: URL(fileURLWithPath: "/Users/a b/Folio.app")
        ).write(to: script, atomically: true, encoding: .utf8)

        let result = UpdateInstaller.run("/bin/sh", ["-n", script.path])
        XCTAssertEqual(result.status, 0, "the script does not parse: \(result.errorText)")
    }

    // MARK: Where we are installed

    /// Under `swift test` there is no Folio.app to replace, and the installer says so rather than
    /// reaching for whatever bundle it happens to be inside.
    func testTheTestRunnerIsNotAnInstalledFolio() {
        XCTAssertNil(UpdateInstaller.installedBundleURL)
    }

    func testAReadOnlyLocationIsReportedRatherThanForced() {
        // `/System` is read-only on every supported macOS, so this needs no fixture.
        XCTAssertFalse(UpdateInstaller.canReplace(
            URL(fileURLWithPath: "/System/Applications/Folio.app")))
    }

    func testAWritableLocationIsAllowed() throws {
        let bundle = try makeBundle(in: try scratch())
        XCTAssertTrue(UpdateInstaller.canReplace(bundle))
    }
}
