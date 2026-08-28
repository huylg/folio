import XCTest
@testable import FolioKit

/// An agent's plan file roots at the workspace of the session that wrote it — recovered from
/// Claude's session transcripts, or matched by content against Cursor's and Codex's known
/// workspaces. The whole config layout is scaffolded in the system temp directory, where no
/// real `.git` or config can interfere.
final class PlanWorkspaceTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    private func makeDirectory(_ path: String) throws -> URL {
        let url = scratch.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ path: String, contents: String = "") throws -> URL {
        let url = scratch.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Claude Code: transcripts name the slug and the cwd

    private func record(slug: String, cwd: String?) -> String {
        let cwdField = cwd.map { ",\"cwd\":\"\($0)\"" } ?? ""
        return "{\"type\":\"user\",\"sessionId\":\"s\"\(cwdField),\"slug\":\"\(slug)\"}"
    }

    @discardableResult
    private func makeTranscript(project: String, session: String, lines: [String],
                                modified: Date? = nil) throws -> URL {
        let url = try makeFile(".claude/projects/\(project)/\(session).jsonl",
                               contents: lines.joined(separator: "\n") + "\n")
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    func testClaudePlanRootsAtTheSessionWorkspace() throws {
        let workspace = try makeDirectory("repo")
        let plan = try makeFile(".claude/plans/misty-moth.md", contents: "# plan")
        try makeTranscript(project: "p", session: "a", lines: [
            "{\"type\":\"mode\",\"mode\":\"normal\"}",
            record(slug: "misty-moth", cwd: workspace.path),
        ])

        XCTAssertEqual(ProjectRoot.detect(for: plan).path, workspace.standardizedFileURL.path)
    }

    /// A subagent's plan is "<slug>-agent-<id>.md", but its transcript records the base slug.
    func testAgentPlanFileMapsToTheBaseSlug() throws {
        let workspace = try makeDirectory("repo")
        let plan = try makeFile(".claude/plans/misty-moth-agent-a8a5dc140b80be383.md",
                                contents: "# plan")
        try makeTranscript(project: "p", session: "a",
                           lines: [record(slug: "misty-moth", cwd: workspace.path)])

        XCTAssertEqual(ProjectRoot.detect(for: plan).path, workspace.standardizedFileURL.path)
    }

    /// The slug match is exact — "misty-moth" must not claim "misty-moth-two"'s session.
    func testASlugThatPrefixesAnotherDoesNotMatchIt() throws {
        let other = try makeDirectory("other")
        let plan = try makeFile(".claude/plans/misty-moth.md", contents: "# plan")
        try makeTranscript(project: "p", session: "a",
                           lines: [record(slug: "misty-moth-two", cwd: other.path)])

        XCTAssertEqual(ProjectRoot.detect(for: plan).path,
                       plan.deletingLastPathComponent().standardizedFileURL.path)
    }

    /// Sessions run in worktrees that are later removed; the plan's paths still describe the
    /// repository's tree, so the root falls back there.
    func testVanishedWorktreeFallsBackToItsRepository() throws {
        let repo = try makeDirectory("repo")
        let goneWorktree = repo.appendingPathComponent(".claude/worktrees/feature-x").path
        let plan = try makeFile(".claude/plans/misty-moth.md", contents: "# plan")
        try makeTranscript(project: "p", session: "a",
                           lines: [record(slug: "misty-moth", cwd: goneWorktree)])

        XCTAssertEqual(ProjectRoot.detect(for: plan).path, repo.standardizedFileURL.path)
    }

    /// Not every record carries a cwd (mode changes, snapshots); the scan keeps looking.
    func testRecordWithoutACwdIsSkipped() throws {
        let workspace = try makeDirectory("repo")
        let plan = try makeFile(".claude/plans/misty-moth.md", contents: "# plan")
        try makeTranscript(project: "p", session: "a", lines: [
            record(slug: "misty-moth", cwd: nil),
            record(slug: "misty-moth", cwd: workspace.path),
        ])

        XCTAssertEqual(ProjectRoot.detect(for: plan).path, workspace.standardizedFileURL.path)
    }

    /// A plan reused across workspaces roots at the most recent session's.
    func testNewestTranscriptWins() throws {
        let old = try makeDirectory("old")
        let new = try makeDirectory("new")
        let plan = try makeFile(".claude/plans/misty-moth.md", contents: "# plan")
        try makeTranscript(project: "p", session: "a",
                           lines: [record(slug: "misty-moth", cwd: old.path)],
                           modified: Date(timeIntervalSinceNow: -3600))
        try makeTranscript(project: "q", session: "b",
                           lines: [record(slug: "misty-moth", cwd: new.path)],
                           modified: Date())

        XCTAssertEqual(ProjectRoot.detect(for: plan).path, new.standardizedFileURL.path)
    }

    /// With no transcript naming the plan, detection falls through to the usual walk — here,
    /// the plan's own folder.
    func testPlanWithoutATranscriptRootsAtItsOwnFolder() throws {
        let plan = try makeFile(".claude/plans/misty-moth.md", contents: "# plan")

        XCTAssertEqual(ProjectRoot.detect(for: plan).path,
                       plan.deletingLastPathComponent().standardizedFileURL.path)
    }

    /// Only an agent config's plans folder gets the lookup; a folder merely named "plans"
    /// does not.
    func testAFolderNamedPlansOutsideAnAgentConfigIsNotSpecial() throws {
        let file = try makeFile("repo/plans/misty-moth.md", contents: "# plan")

        XCTAssertNil(PlanWorkspace.resolve(for: file))
    }

    // MARK: - Codex: session rollouts open with the cwd, content picks the workspace

    func testCodexPlanRootsAtTheSessionWorkspaceItsContentDescribes() throws {
        let workspace = try makeDirectory("repo")
        _ = try makeFile("repo/src/utils/voucher.py")
        let plan = try makeFile(
            ".codex/plans/split-the-voucher-record.md",
            contents: "Fix [voucher.py:1043](src/utils/voucher.py:1043) first.")
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"s\",\"cwd\":\"\(workspace.path)\"}}"
        _ = try makeFile(".codex/sessions/2026/08/rollout-a.jsonl", contents: meta + "\n")

        XCTAssertEqual(ProjectRoot.detect(for: plan).path, workspace.standardizedFileURL.path)
    }

    func testCodexSessionsWhoseTreesLackThePlansFilesAreNotChosen() throws {
        let wrong = try makeDirectory("unrelated")
        let plan = try makeFile(".codex/plans/split-the-voucher-record.md",
                                contents: "Fix [voucher.py](src/utils/voucher.py) first.")
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"s\",\"cwd\":\"\(wrong.path)\"}}"
        _ = try makeFile(".codex/sessions/2026/08/rollout-a.jsonl", contents: meta + "\n")

        XCTAssertEqual(ProjectRoot.detect(for: plan).path,
                       plan.deletingLastPathComponent().standardizedFileURL.path)
    }

    // MARK: - Cursor: known workspaces, content picks the one described

    func testCursorWorkspacesAreReadFromWorkspaceStorage() throws {
        let workspace = try makeDirectory("repo")
        _ = try makeFile("storage/abc/workspace.json",
                         contents: "{\"folder\": \"file://\(workspace.path)\"}")
        _ = try makeFile("storage/def/workspace.json", contents: "{\"other\": true}")

        let found = PlanWorkspace.cursorWorkspaces(
            storage: scratch.appendingPathComponent("storage"), fileManager: .default)
        XCTAssertEqual(found.map(\.path), [workspace.standardizedFileURL.path])
    }

    func testCursorPlanRootsAtTheListedWorkspaceItsContentDescribes() throws {
        // The resolver also consults the machine's real Cursor storage, so the referenced
        // filename must be one no real workspace could contain.
        let filename = "app-\(UUID().uuidString).ts"
        let workspace = try makeDirectory("repo")
        _ = try makeFile("repo/src/\(filename)")
        _ = try makeFile(".cursor/unified_repo_list.json",
                         contents: "[{\"path\": \"\(workspace.path)\"}]")
        let plan = try makeFile(".cursor/plans/refactor-app.plan.md",
                                contents: "Touch `src/\(filename)` and nothing else.")

        XCTAssertEqual(ProjectRoot.detect(for: plan).path, workspace.standardizedFileURL.path)
    }

    // MARK: - Content matching

    func testFileReferencesFindLinksAndCodeSpans() {
        let source = """
        See [voucher.py:1043](payment-server/src/voucher.py:1043) and
        [docs](/docs/setup.md#install), plus `Sources/App/main.swift` — but not
        [web](https://example.com/x.md), `no spaces here / allowed`, or `plain`.
        """
        XCTAssertEqual(PlanWorkspace.fileReferences(in: source),
                       ["payment-server/src/voucher.py", "docs/setup.md",
                        "Sources/App/main.swift"])
    }

    /// Two candidates both hold some of the plan's files; the fuller match wins even when it
    /// is the older workspace.
    func testTheWorkspaceHoldingMoreOfThePlansFilesWins() throws {
        let partial = try makeDirectory("partial")
        _ = try makeFile("partial/src/a.swift")
        let full = try makeDirectory("full")
        _ = try makeFile("full/src/a.swift")
        _ = try makeFile("full/src/b.swift")
        let plan = try makeFile("plan.md", contents: "Edit `src/a.swift` and `src/b.swift`.")

        let match = PlanWorkspace.workspaceMatchingContent(
            of: plan, candidates: [partial, full], fileManager: .default)
        XCTAssertEqual(match?.path, full.standardizedFileURL.path)
    }

    func testAPlanWithNoFileReferencesMatchesNothing() throws {
        let workspace = try makeDirectory("repo")
        let plan = try makeFile("plan.md", contents: "# Just prose, no paths.")

        XCTAssertNil(PlanWorkspace.workspaceMatchingContent(
            of: plan, candidates: [workspace], fileManager: .default))
    }
}
