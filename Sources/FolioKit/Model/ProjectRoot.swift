import Foundation

/// The project root of a document: the nearest ancestor directory containing a `.git`
/// entry — a directory for a normal checkout, a file for a worktree or submodule.
/// A document outside any repository roots at its own folder.
///
/// A coding agent's plan file is the exception: it lives in a flat plans folder under the
/// agent's config directory but describes a workspace elsewhere, so it roots at the
/// workspace of the session that wrote it (see `PlanWorkspace`).
public enum ProjectRoot {
    public static func detect(for fileURL: URL,
                              fileManager: FileManager = .default) -> URL {
        if let workspace = PlanWorkspace.resolve(for: fileURL, fileManager: fileManager) {
            return workspace
        }
        let startDirectory = fileURL.deletingLastPathComponent().standardizedFileURL
        var candidate = startDirectory
        while true {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            // `deletingLastPathComponent()` of "/" yields "/..", not "/", so the terminal
            // check must standardize — comparing raw paths would loop forever.
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { return startDirectory }
            candidate = parent
        }
    }
}
