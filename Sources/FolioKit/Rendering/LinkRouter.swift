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

        let url: URL
        if path.hasPrefix("/"), let root {
            var trimmed = path
            // "//x" must not fall back to filesystem-absolute and escape the root.
            while trimmed.hasPrefix("/") { trimmed.removeFirst() }
            url = trimmed.isEmpty
                ? root.standardizedFileURL
                : URL(fileURLWithPath: trimmed, relativeTo: root).standardizedFileURL
        } else {
            url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing(destination)
        }
        return isMarkdownFile(url) ? .markdown(url, fragment: fragment) : .file(url)
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
