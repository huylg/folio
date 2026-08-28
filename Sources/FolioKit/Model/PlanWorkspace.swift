import Foundation

/// Maps a coding agent's plan file back to the workspace of the session that wrote it.
///
/// Claude Code, Cursor, and Codex all keep plan files in one flat folder under their config
/// directory (`~/.claude/plans`, `~/.cursor/plans`, `~/.codex/plans`), so `.git` walking
/// roots them at the plans folder — but a plan's links and run commands are written relative
/// to the session's working directory. Each tool records that directory somewhere else:
///
/// - Claude Code names the plan's slug in its session transcripts
///   (`~/.claude/projects/**/*.jsonl`), on records that also carry the session's `cwd`.
/// - Cursor and Codex keep no such link, but both remember their workspaces — Cursor in
///   `workspaceStorage`, Codex in each session rollout's opening record — and the plan's own
///   file references say which of those workspaces it describes.
public enum PlanWorkspace {

    /// The workspace of the session that produced `fileURL`, or nil when the file is not an
    /// agent plan or no workspace can be recovered.
    public static func resolve(for fileURL: URL,
                               fileManager: FileManager = .default) -> URL? {
        let file = fileURL.standardizedFileURL
        let plansDirectory = file.deletingLastPathComponent()
        let configDirectory = plansDirectory.deletingLastPathComponent()
        guard plansDirectory.lastPathComponent == "plans" else { return nil }

        switch configDirectory.lastPathComponent {
        case ".claude":
            return claudeWorkspace(for: file, configDirectory: configDirectory,
                                   fileManager: fileManager)
        case ".cursor":
            var candidates = cursorWorkspaces(storage: cursorWorkspaceStorage(fileManager: fileManager),
                                              fileManager: fileManager)
            candidates += repoList(in: configDirectory)
            return workspaceMatchingContent(of: file, candidates: candidates,
                                            fileManager: fileManager)
        case ".codex":
            return workspaceMatchingContent(of: file,
                                            candidates: codexWorkspaces(in: configDirectory,
                                                                        fileManager: fileManager),
                                            fileManager: fileManager)
        default:
            return nil
        }
    }

    // MARK: - Claude Code

    private static func claudeWorkspace(for file: URL, configDirectory: URL,
                                        fileManager: FileManager) -> URL? {
        var slug = file.deletingPathExtension().lastPathComponent
        // A subagent's plan file is named "<slug>-agent-<id>.md", but its transcript records
        // the base slug.
        if let agentSuffix = slug.range(of: "-agent-[0-9a-f]+$", options: .regularExpression) {
            slug.removeSubrange(agentSuffix)
        }
        guard !slug.isEmpty else { return nil }
        let needle = Data("\"slug\":\"\(slug)\"".utf8)

        let projectsDirectory = configDirectory.appendingPathComponent("projects", isDirectory: true)
        for transcript in jsonlFiles(under: projectsDirectory, fileManager: fileManager) {
            guard let cwd = firstWorkingDirectory(in: transcript, matching: needle),
                  let workspace = existingWorkspace(for: cwd, fileManager: fileManager)
            else { continue }
            return workspace
        }
        return nil
    }

    /// The session `cwd` on the first record naming the slug. Mapped rather than read so a
    /// miss over a large transcript costs a scan, not a copy; a record is only parsed as
    /// JSON once the raw bytes contain the slug.
    private static func firstWorkingDirectory(in transcript: URL, matching needle: Data) -> String? {
        guard let data = try? Data(contentsOf: transcript, options: .mappedIfSafe) else { return nil }
        let newline = UInt8(ascii: "\n")
        var searchFrom = data.startIndex
        while let hit = data.range(of: needle, in: searchFrom..<data.endIndex) {
            searchFrom = hit.upperBound
            let lineStart = data[data.startIndex..<hit.lowerBound].lastIndex(of: newline)
                .map(data.index(after:)) ?? data.startIndex
            let lineEnd = data[hit.upperBound..<data.endIndex].firstIndex(of: newline) ?? data.endIndex
            guard let record = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]),
                  let cwd = (record as? [String: Any])?["cwd"] as? String
            else { continue }
            return cwd
        }
        return nil
    }

    /// The recorded `cwd` if it still exists. A session run in a worktree outlives the
    /// worktree itself — those live under `<repo>/.claude/worktrees/<name>` and are removed
    /// when the branch merges — so a vanished worktree falls back to its repository, whose
    /// tree the plan's paths still describe.
    private static func existingWorkspace(for cwd: String, fileManager: FileManager) -> URL? {
        if isDirectory(cwd, fileManager: fileManager) {
            return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        }
        guard let marker = cwd.range(of: "/.claude/worktrees/") else { return nil }
        let repo = String(cwd[..<marker.lowerBound])
        guard isDirectory(repo, fileManager: fileManager) else { return nil }
        return URL(fileURLWithPath: repo, isDirectory: true).standardizedFileURL
    }

    // MARK: - Cursor

    static func cursorWorkspaceStorage(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cursor/User/workspaceStorage", isDirectory: true)
    }

    /// The folders Cursor has opened, newest first, from each storage entry's
    /// `workspace.json` (`{"folder": "file:///…"}`).
    static func cursorWorkspaces(storage: URL?, fileManager: FileManager) -> [URL] {
        guard let storage,
              let entries = try? fileManager.contentsOfDirectory(
                  at: storage, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        var dated: [(url: URL, modified: Date)] = []
        for entry in entries {
            let manifest = entry.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: manifest),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let folder = record["folder"] as? String,
                  let url = URL(string: folder), url.isFileURL
            else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            dated.append((url.standardizedFileURL, modified))
        }
        return dated.sorted { $0.modified > $1.modified }.map(\.url)
    }

    /// Cursor's `unified_repo_list.json`, read tolerantly — strings, or objects with a
    /// path-valued field — since its schema is not documented.
    private static func repoList(in configDirectory: URL) -> [URL] {
        let manifest = configDirectory.appendingPathComponent("unified_repo_list.json")
        guard let data = try? Data(contentsOf: manifest),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        return entries.compactMap { entry in
            if let path = entry as? String, path.hasPrefix("/") { return path }
            guard let record = entry as? [String: Any] else { return nil }
            for key in ["path", "rootPath", "repoPath", "folder"] {
                if let path = record[key] as? String, path.hasPrefix("/") { return path }
            }
            return nil
        }.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    // MARK: - Codex

    /// The working directory of every Codex session, newest first. Each rollout's first
    /// record is `session_meta` with a `payload.cwd`; only that line is read.
    static func codexWorkspaces(in configDirectory: URL, fileManager: FileManager) -> [URL] {
        let sessions = configDirectory.appendingPathComponent("sessions", isDirectory: true)
        var seen = Set<String>()
        var workspaces: [URL] = []
        for rollout in jsonlFiles(under: sessions, fileManager: fileManager) {
            guard let record = firstRecord(of: rollout),
                  let payload = record["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String,
                  seen.insert(cwd).inserted
            else { continue }
            workspaces.append(URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL)
        }
        return workspaces
    }

    private static func firstRecord(of jsonl: URL) -> [String: Any]? {
        // The opening record carries the session's full base instructions, so it can run to
        // tens of kilobytes — but not to this bound.
        guard let handle = try? FileHandle(forReadingFrom: jsonl) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 262_144) else { return nil }
        let line = data.firstIndex(of: UInt8(ascii: "\n")).map { data[data.startIndex..<$0] } ?? data
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    // MARK: - Matching a plan's content against candidate workspaces

    /// The candidate holding the most of the plan's file references — ties to the most
    /// recent. A plan names the files it intends to touch, and those paths exist under the
    /// workspace it was written for and almost nowhere else.
    static func workspaceMatchingContent(of file: URL, candidates: [URL],
                                         fileManager: FileManager) -> URL? {
        guard !candidates.isEmpty,
              let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let references = fileReferences(in: source)
        guard !references.isEmpty else { return nil }

        var best: (workspace: URL, score: Int)?
        for candidate in candidates {
            guard isDirectory(candidate.path, fileManager: fileManager) else { continue }
            let score = references.filter { reference in
                fileManager.fileExists(atPath: candidate.appendingPathComponent(reference).path)
            }.count
            if score == references.count {
                return candidate
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (candidate, score)
            }
        }
        return best?.workspace
    }

    /// Workspace-relative paths the plan mentions: link destinations and `code`-span paths,
    /// with fragments, trailing `:line[:column]` suffixes, and leading slashes stripped.
    static func fileReferences(in source: String) -> [String] {
        var references: [String] = []
        var seen = Set<String>()
        let range = NSRange(source.startIndex..., in: source)
        let patterns = [
            #"\]\(([^)\s]+)\)"#,          // markdown link destination
            #"`([^`\n]*/[^`\n]*)`"#,      // a code span containing a slash
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            expression.enumerateMatches(in: source, range: range) { match, _, stop in
                guard let match, let captured = Range(match.range(at: 1), in: source) else { return }
                guard let reference = normalizeReference(String(source[captured])),
                      seen.insert(reference).inserted else { return }
                references.append(reference)
                if references.count >= 32 { stop.pointee = true }
            }
        }
        return references
    }

    private static func normalizeReference(_ raw: String) -> String? {
        var path = raw
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        path = path.removingPercentEncoding ?? path
        // "[voucher.py:1043](src/voucher.py:1043)" points at the file, not a file named with
        // a colon.
        if let lineSuffix = path.range(of: ":[0-9]+(:[0-9]+)?$", options: .regularExpression) {
            path.removeSubrange(lineSuffix)
        }
        // A leading slash in a plan means the workspace root, not the filesystem.
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty, !path.hasPrefix("~"), path.contains("/"),
              !path.contains(" "), !path.contains("://"), !path.hasPrefix("mailto:")
        else { return nil }
        return path
    }

    // MARK: - Shared

    /// Every `.jsonl` under `directory`, newest first. A plan is almost always opened near
    /// the session that wrote it, so recency order lets scans stop at the first file in
    /// practice.
    private static func jsonlFiles(under directory: URL, fileManager: FileManager) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = fileManager.enumerator(at: directory,
                                                  includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles]) else { return [] }
        var dated: [(url: URL, modified: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            dated.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return dated.sorted { $0.modified > $1.modified }.map(\.url)
    }

    private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
