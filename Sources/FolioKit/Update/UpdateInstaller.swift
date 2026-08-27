import AppKit
import CryptoKit

/// Fetches a release, checks it is what it claims to be, and swaps it in.
///
/// Every step before the swap happens in a scratch directory, and the swap itself moves the old
/// bundle aside rather than deleting it, so a failure at any point leaves the installed app
/// exactly as it was.
public final class UpdateInstaller: NSObject, URLSessionDownloadDelegate {

    public static let expectedBundleIdentifier = "io.huylg.folio"

    private var session: URLSession?
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((Result<URL, UpdateError>) -> Void)?
    private var release: Release?
    private var scratch: URL?

    // MARK: - Download

    /// Downloads and validates `release`, calling back on the main queue with the unpacked
    /// `Folio.app` sitting in a scratch directory, ready to install.
    public func fetch(_ release: Release,
                      progress: @escaping (Double) -> Void,
                      completion: @escaping (Result<URL, UpdateError>) -> Void) {
        self.release = release
        self.onProgress = progress
        self.onFinish = completion

        guard UpdateSource.isAllowedAssetURL(release.assetURL) else {
            finish(.failure(.noUsableAsset))
            return
        }

        var request = URLRequest(url: release.assetURL)
        request.setValue("Folio", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: request).resume()
    }

    /// Abandons an in-flight download. The scratch directory goes with it.
    public func cancel() {
        session?.invalidateAndCancel()
        session = nil
        onProgress = nil
        onFinish = nil
        discardScratch()
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        // The server does not always send a length; the release payload carries one, so fall back
        // to it rather than showing a bar that never moves.
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (release?.byteCount ?? 0)
        guard expected > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(expected))
        DispatchQueue.main.async { [weak self] in self?.onProgress?(fraction) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let release else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(.badResponse(http.statusCode)))
            return
        }
        // A redirect that left GitHub would have been followed by now; refuse the bytes rather
        // than unpacking something from wherever it ended up.
        if let final = downloadTask.response?.url, !UpdateSource.isAllowedAssetURL(final) {
            finish(.failure(.noUsableAsset))
            return
        }

        // `location` is deleted the moment this method returns, so the archive has to be moved
        // before anything else happens to it.
        let scratch: URL
        let archive: URL
        do {
            scratch = try Self.makeScratchDirectory()
            self.scratch = scratch
            archive = scratch.appendingPathComponent(release.assetName)
            try FileManager.default.moveItem(at: location, to: archive)
        } catch {
            finish(.failure(.downloadFailed(error.localizedDescription)))
            return
        }

        finish(Self.verifyAndUnpack(archive: archive, release: release, in: scratch))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let error else { return }
        // Cancellation is our own doing and has already been reported.
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(.downloadFailed(error.localizedDescription)))
    }

    private func finish(_ result: Result<URL, UpdateError>) {
        let callback = onFinish
        onFinish = nil
        onProgress = nil
        session?.finishTasksAndInvalidate()
        session = nil
        if case .failure = result { discardScratch() }
        DispatchQueue.main.async { callback?(result) }
    }

    private func discardScratch() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
    }

    // MARK: - Verify and unpack

    /// The whole check, as one function with no network in it, so the tests can run it against an
    /// archive they built themselves.
    static func verifyAndUnpack(archive: URL, release: Release, in scratch: URL)
        -> Result<URL, UpdateError> {

        if let expected = release.checksumURL {
            switch downloadChecksum(from: expected) {
            case .failure(let error):
                return .failure(error)
            case .success(let digest):
                guard let actual = sha256(ofFileAt: archive), actual == digest else {
                    return .failure(.checksumMismatch)
                }
            }
        }

        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        } catch {
            return .failure(.corruptArchive(error.localizedDescription))
        }

        let extracted = archive.pathExtension.lowercased() == "dmg"
            ? copyAppOutOfImage(archive, into: unpacked)
            : unzip(archive, into: unpacked)

        switch extracted {
        case .failure(let error):
            return .failure(error)
        case .success(let bundle):
            if let problem = validate(bundleAt: bundle) { return .failure(problem) }
            return .success(bundle)
        }
    }

    /// `ditto -x -k`, matching the `ditto -c -k` that produced the zips up to v1.3.0: it is the
    /// tool that round-trips a bundle's symlinks and executable bits, which `unzip` does not.
    static func unzip(_ archive: URL, into directory: URL) -> Result<URL, UpdateError> {
        let result = run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        guard result.status == 0 else {
            return .failure(.corruptArchive(result.errorText))
        }
        guard let bundle = firstAppBundle(in: directory) else {
            return .failure(.notFolio("No Folio.app inside the archive."))
        }
        return .success(bundle)
    }

    /// Mounts the release image, copies the app off it, and unmounts.
    ///
    /// Mounted read-only at a mount point of our own inside the scratch directory, and `-nobrowse`
    /// so a background update never puts a volume on the reader's desktop. The detach is in a
    /// `defer`: an image left mounted because the copy failed is a volume the reader has to eject
    /// by hand to be rid of.
    static func copyAppOutOfImage(_ image: URL, into directory: URL) -> Result<URL, UpdateError> {
        let mountPoint = directory.deletingLastPathComponent()
            .appendingPathComponent("mount", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mountPoint,
                                                    withIntermediateDirectories: true)
        } catch {
            return .failure(.corruptArchive(error.localizedDescription))
        }

        if case .failure(let error) = attach(image, at: mountPoint) {
            return .failure(error)
        }
        defer {
            detach(mountPoint)
            try? FileManager.default.removeItem(at: mountPoint)
        }

        guard let source = firstAppBundle(in: mountPoint) else {
            return .failure(.notFolio("No Folio.app inside the disk image."))
        }
        // Copied off before the image is unmounted, and with `ditto` again so the bundle arrives
        // whole. The `Applications` symlink beside it on the image is not ours to take.
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let copy = run("/usr/bin/ditto", [source.path, destination.path])
        guard copy.status == 0 else {
            return .failure(.corruptArchive(copy.errorText))
        }
        return .success(destination)
    }

    /// How many times a mount held up by a busy machine is worth trying. The waits between them
    /// lengthen, so this is around fifteen seconds of patience in total — long enough to outlast
    /// the contention that produces these failures, and only ever spent when `hdiutil` has said
    /// that contention is what went wrong.
    static let mountAttempts = 6

    /// How many times a mount is worth trying when `hdiutil` blamed the image rather than the
    /// machine. More than one because the diagnosis is a string we are reading by hand, and a
    /// wording we have not seen should still get the benefit of a second try; not many more
    /// because a file that is not a disk image will never become one.
    static let unrecognizedImageAttempts = 2

    /// `hdiutil attach`, retried.
    ///
    /// Mounting is the one step in the unpack that fails for reasons that have nothing to do with
    /// the bytes we downloaded: disk arbitration is busy, another image is still detaching, the
    /// machine is loaded. `hdiutil` exits non-zero either way, but it does say which — "Resource
    /// temporarily unavailable" for contention, "no mountable file systems" for a file that is not
    /// an image — so a loaded machine gets waited out while a bad download is refused promptly.
    ///
    /// Run without `-quiet` so a refusal can say why; `-quiet` suppresses the diagnosis too, and
    /// "The disk image would not mount." with nothing after it is not something a reader, or a CI
    /// log, can act on.
    static func attach(_ image: URL, at mountPoint: URL) -> Result<Void, UpdateError> {
        var complaint = ""
        for attempt in 1...mountAttempts {
            let attach = run("/usr/bin/hdiutil", [
                "attach", image.path,
                "-mountpoint", mountPoint.path,
                "-nobrowse", "-readonly", "-noautoopen",
            ])
            if attach.status == 0 { return .success(()) }
            complaint = attach.errorText.isEmpty ? attach.outputText : attach.errorText

            let budget = isMachineBusy(complaint) ? mountAttempts : unrecognizedImageAttempts
            guard attempt < budget else { break }
            // Clear whatever a half-finished attach left behind, and give disk arbitration a
            // moment: retrying into a mount point it is still working on fails the same way.
            // One try only — an attach that failed usually left nothing to detach, and this is
            // tidying up before the wait rather than the unmount that has to succeed.
            detach(mountPoint, attempts: 1)
            Thread.sleep(forTimeInterval: Double(attempt))
        }
        return .failure(.corruptArchive(
            complaint.isEmpty ? "The disk image would not mount." : complaint))
    }

    /// Whether `hdiutil` is complaining about the state of the machine rather than the image —
    /// the kernel's own errno text, as it comes back through `hdiutil` when the framework it
    /// drives is out of a resource or still holding one from an earlier mount.
    static func isMachineBusy(_ complaint: String) -> Bool {
        let text = complaint.lowercased()
        return ["resource temporarily unavailable",
                "resource busy",
                "device busy",
                "device not configured",
                "operation timed out"].contains { text.contains($0) }
    }

    /// Unmounts, retried.
    ///
    /// `-force` because a Finder or Spotlight peek can hold the volume briefly. A detach that
    /// loses that race anyway leaves an image attached, which is both a volume the reader has to
    /// eject by hand and one more attachment against whatever limit the next mount runs into.
    static func detach(_ mountPoint: URL, attempts: Int = 3) {
        for attempt in 1...max(1, attempts) {
            let result = run("/usr/bin/hdiutil",
                             ["detach", mountPoint.path, "-force", "-quiet"])
            if result.status == 0 { return }
            if attempt < attempts { Thread.sleep(forTimeInterval: 0.5) }
        }
    }

    static func firstAppBundle(in directory: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.lastPathComponent == "Folio.app" }
            ?? entries.first { $0.pathExtension == "app" }
    }

    /// Everything that has to be true of a bundle before it is allowed to replace the running app.
    /// Returns nil when it passes.
    static func validate(bundleAt url: URL, minimumVersion: AppVersion? = nil) -> UpdateError? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .notFolio("The archive did not contain an app bundle.")
        }
        guard url.pathExtension == "app" else {
            return .notFolio("\(url.lastPathComponent) is not an app bundle.")
        }

        let executable = url.appendingPathComponent("Contents/MacOS/Folio")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .notFolio("Its executable is missing or not runnable.")
        }

        guard let bundle = Bundle(url: url),
              let identifier = bundle.infoDictionary?["CFBundleIdentifier"] as? String
        else {
            return .notFolio("It has no readable Info.plist.")
        }
        guard identifier == expectedBundleIdentifier else {
            return .notFolio("It identifies itself as \(identifier).")
        }
        guard let version = AppVersion.fromBundle(bundle) else {
            return .notFolio("It does not report a version.")
        }
        if let minimumVersion, version <= minimumVersion {
            return .notFolio("It is version \(version), which is not newer than \(minimumVersion).")
        }
        return nil
    }

    // MARK: - Checksum

    /// Fetched synchronously: this runs on the download delegate's queue, never the main one, and
    /// the file is a single line of hex.
    static func downloadChecksum(from url: URL) -> Result<String, UpdateError> {
        guard UpdateSource.isAllowedAssetURL(url) else { return .failure(.noUsableAsset) }

        var request = URLRequest(url: url)
        request.setValue("Folio", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        var outcome: Result<String, UpdateError> = .failure(.malformedFeed)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                outcome = .failure(.network(error.localizedDescription))
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                outcome = .failure(.badResponse(http.statusCode))
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                outcome = .failure(.malformedFeed)
                return
            }
            outcome = normalizeChecksum(text).map { .success($0) } ?? .failure(.malformedFeed)
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return outcome
    }

    /// Accepts both a bare digest and `shasum`'s `<digest>  <filename>` line.
    static func normalizeChecksum(_ raw: String) -> String? {
        guard let field = raw.split(whereSeparator: \.isWhitespace).first else { return nil }
        let digest = field.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
        return digest
    }

    /// Streamed in chunks: a release archive is a few megabytes today, but reading a download
    /// wholly into memory to hash it is a habit that gets expensive quietly.
    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Install

    /// Where the running app lives, or nil when this is not an installed bundle — a `swift run`
    /// build, or the xctest runner.
    public static var installedBundleURL: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        guard Bundle.main.bundleIdentifier == expectedBundleIdentifier else { return nil }
        return url
    }

    /// Whether we could replace the bundle in place. An app in `/Applications` under a standard
    /// account cannot be, and Folio does not ask for an administrator to work around it: the
    /// reader gets the unpacked copy revealed in the Finder instead.
    public static func canReplace(_ bundle: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: bundle.path)
    }

    /// Swaps `replacement` in for `bundle` and relaunches.
    ///
    /// The swap cannot happen from inside the process being replaced, so it is handed to a short
    /// script that waits for us to exit first. The script moves the old bundle aside rather than
    /// deleting it, and puts it back if the copy fails, so an interrupted update leaves a working
    /// app behind.
    public static func install(replacement: URL, over bundle: URL) -> UpdateError? {
        guard canReplace(bundle) else {
            return .notWritable(bundle.deletingLastPathComponent().path)
        }

        let script: URL
        do {
            script = try makeScratchDirectory().appendingPathComponent("install.sh")
            try swapScript(replacement: replacement, destination: bundle)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        } catch {
            return .installFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)"]
        do {
            try process.run()
        } catch {
            return .installFailed(error.localizedDescription)
        }
        return nil
    }

    static func swapScript(replacement: URL, destination: URL) -> String {
        let new = shellQuoted(replacement.path)
        let dest = shellQuoted(destination.path)
        return """
        #!/bin/sh
        # Written by Folio's updater and run detached, so it outlives the app it replaces.
        pid="$1"
        # Wait for Folio to exit: the bundle cannot be swapped while its executable is mapped.
        n=0
        while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 300 ]; do
            sleep 0.2
            n=$((n + 1))
        done

        new=\(new)
        dest=\(dest)
        backup="$dest.folio-previous"

        rm -rf "$backup"
        mv "$dest" "$backup" || exit 1
        if /usr/bin/ditto "$new" "$dest"; then
            # An archive fetched over the network can carry a quarantine flag, and Folio is signed
            # ad hoc — Gatekeeper would refuse the relaunch outright rather than prompting.
            /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null
            rm -rf "$backup"
        else
            rm -rf "$dest"
            mv "$backup" "$dest"
        fi

        /usr/bin/open "$dest"
        rm -rf "$(dirname "$0")"
        """
    }

    /// Single quotes with the one escape single quoting needs, so a path with a space or an
    /// apostrophe in it cannot become two arguments or a syntax error.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Plumbing

    static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String])
        -> (status: Int32, errorText: String, outputText: String) {
        let result = ProcessRunner.run(path, arguments)
        return (result.status, result.errorText, result.outputText)
    }
}
