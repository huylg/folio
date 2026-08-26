import Foundation

/// The project root of a document: the nearest ancestor directory containing a `.git`
/// entry — a directory for a normal checkout, a file for a worktree or submodule.
/// A document outside any repository roots at its own folder.
public enum ProjectRoot {
    public static func detect(for fileURL: URL,
                              fileManager: FileManager = .default) -> URL {
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
