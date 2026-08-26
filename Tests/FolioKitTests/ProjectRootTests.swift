import XCTest
@testable import FolioKit

/// Root detection walks up from the document's folder to the nearest `.git` entry.
/// All scaffolding lives in the system temp directory — a `.git` fixture committed to
/// this repo would confuse git itself, and temp dirs have no `.git` above them.
final class ProjectRootTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    private func makeDirectory(_ components: String...) throws -> URL {
        var url = scratch!
        for component in components { url.appendPathComponent(component, isDirectory: true) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(at url: URL, contents: String = "") throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFindsGitDirectoryAncestor() throws {
        let repo = try makeDirectory("repo")
        _ = try makeDirectory("repo", ".git")
        let docs = try makeDirectory("repo", "docs", "notes")
        let file = docs.appendingPathComponent("a.md")
        try makeFile(at: file, contents: "# a")

        XCTAssertEqual(ProjectRoot.detect(for: file).path, repo.standardizedFileURL.path)
    }

    func testFindsGitFileAncestorAsInAWorktree() throws {
        let repo = try makeDirectory("worktree")
        try makeFile(at: repo.appendingPathComponent(".git"),
                     contents: "gitdir: /somewhere/.git/worktrees/x")
        let file = repo.appendingPathComponent("a.md")
        try makeFile(at: file, contents: "# a")

        XCTAssertEqual(ProjectRoot.detect(for: file).path, repo.standardizedFileURL.path)
    }

    func testNearestRepositoryWinsWhenNested() throws {
        _ = try makeDirectory("outer", ".git")
        let inner = try makeDirectory("outer", "vendor", "inner")
        _ = try makeDirectory("outer", "vendor", "inner", ".git")
        let deep = try makeDirectory("outer", "vendor", "inner", "src")
        let file = deep.appendingPathComponent("a.md")
        try makeFile(at: file, contents: "# a")

        XCTAssertEqual(ProjectRoot.detect(for: file).path, inner.standardizedFileURL.path)
    }

    func testFallsBackToTheFilesOwnFolderWithoutAMarker() throws {
        let folder = try makeDirectory("plain", "notes")
        let file = folder.appendingPathComponent("a.md")
        try makeFile(at: file, contents: "# a")

        XCTAssertEqual(ProjectRoot.detect(for: file).path, folder.standardizedFileURL.path)
    }

    func testMarkdownDocumentExposesTheDetectedRoot() throws {
        let repo = try makeDirectory("docrepo")
        _ = try makeDirectory("docrepo", ".git")
        let file = repo.appendingPathComponent("a.md")
        try makeFile(at: file, contents: "# a")

        let document = try MarkdownDocument(url: file)
        XCTAssertEqual(document.rootURL.path, repo.standardizedFileURL.path)
    }
}
