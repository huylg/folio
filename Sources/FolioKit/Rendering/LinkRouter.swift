import AppKit

/// Classifies a Markdown link destination.
///
/// The web view resolved relative paths for free via its `baseURL:`; natively this has to be
/// explicit, and `URL(string:)` is the wrong tool for a relative file destination. It produces
/// a schemeless URL whose `path` is relative, so any filesystem call on it resolves against the
/// process working directory rather than the document's folder — and on older systems it simply
/// returns nil for a path containing a space, which the sample vault has.
/// `URL(fileURLWithPath:relativeTo:)` over a percent-decoded string is correct on both counts.
public enum LinkTarget: Equatable {
    /// http, https, or mailto — hand to the system.
    case external(URL)
    /// A `#fragment` in the current document.
    case fragment(String)
    /// A Markdown file, optionally with a fragment to scroll to on arrival.
    case markdown(URL, fragment: String?)
    /// Some other local file — hand to the system.
    case file(URL)
    /// A relative path that does not exist. The web view silently 404'd these.
    case missing(String)
}

/// Extensions Folio treats as Markdown.
public func isMarkdownFile(_ url: URL) -> Bool {
    ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
}

public enum LinkRouter {

    /// `base` is the document's own folder; `root` is its project root (see `ProjectRoot`).
    /// A destination starting with `/` resolves against `root` rather than the filesystem —
    /// inside a repository, "/docs/setup.md" means the repo's docs, never the machine's.
    public static func resolve(_ destination: String, relativeTo base: URL, root: URL? = nil) -> LinkTarget {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .missing(destination) }

        if trimmed.hasPrefix("#") {
            return .fragment(String(trimmed.dropFirst()))
        }

        // Absolute URLs with a scheme we hand off. Checked before the file path branch so a
        // "https://…" is never treated as a relative filename.
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp"].contains(scheme) {
            return .external(url)
        }

        let (rawPath, fragment) = splitFragment(trimmed)
        // A destination may be percent-encoded ("a%20b.md") or literal ("a b.md"); both must
        // resolve to the same file.
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard !path.isEmpty else {
            return fragment.map { LinkTarget.fragment($0) } ?? .missing(destination)
        }

        // Agent plans link with a line suffix — "[voucher.py:1043](src/voucher.py:1043)" —
        // which names the file, not a file with a colon. The literal path is tried first,
        // since a filename may genuinely contain a colon.
        guard let url = locate(path, base: base, root: root)
                ?? strippingLineSuffix(path).flatMap({ locate($0, base: base, root: root) })
        else {
            return .missing(destination)
        }
        return isMarkdownFile(url) ? .markdown(url, fragment: fragment) : .file(url)
    }

    /// The existing file `path` names, or nil.
    private static func locate(_ path: String, base: URL, root: URL?) -> URL? {
        if path.hasPrefix("/"), let root {
            var trimmed = path
            // "//x" must not fall back to filesystem-absolute and escape the root.
            while trimmed.hasPrefix("/") { trimmed.removeFirst() }
            let url = trimmed.isEmpty
                ? root.standardizedFileURL
                : URL(fileURLWithPath: trimmed, relativeTo: root).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let atBase = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        if FileManager.default.fileExists(atPath: atBase.path) { return atBase }
        // A relative destination missing beside the document may still name a file from the
        // root — documents that live outside the tree they describe (an agent's plan in
        // `~/.claude/plans`) write their paths root-relative.
        if let root {
            let atRoot = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            if FileManager.default.fileExists(atPath: atRoot.path) { return atRoot }
        }
        return nil
    }

    private static func strippingLineSuffix(_ path: String) -> String? {
        guard let suffix = path.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression)
        else { return nil }
        return String(path[..<suffix.lowerBound])
    }

    /// Splits a trailing `#fragment`, ignoring a `#` that is part of the filename itself only
    /// insofar as the last one wins — which matches how browsers behave.
    private static func splitFragment(_ destination: String) -> (path: String, fragment: String?) {
        guard let hash = destination.lastIndex(of: "#") else { return (destination, nil) }
        let path = String(destination[..<hash])
        let fragment = String(destination[destination.index(after: hash)...])
        return (path, fragment.isEmpty ? nil : fragment)
    }
}
