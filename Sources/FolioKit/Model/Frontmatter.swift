import Foundation

/// Minimal YAML-ish frontmatter: a leading `---` block of `key: value` pairs.
/// Supports inline arrays `[a, b]`, quoted strings, and `- item` list continuation.
public struct Frontmatter {
    public private(set) var orderedKeys: [String] = []
    public private(set) var values: [String: FrontmatterValue] = [:]

    public var isEmpty: Bool { orderedKeys.isEmpty }

    public var tags: [String] {
        for key in ["tags", "tag", "keywords"] {
            if case .list(let items)? = values[key] { return items }
            if case .scalar(let s)? = values[key] {
                return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        return []
    }

    /// Returns (frontmatter, remaining markdown body).
    public static func parse(_ text: String) -> (Frontmatter, String) {
        var fm = Frontmatter()
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (fm, text) }

        var end = -1
        for i in 1..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { end = i; break }
        }
        guard end > 0 else { return (fm, text) }

        var currentKey: String?
        for raw in lines[1..<end] {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("- "), let key = currentKey {
                let item = clean(String(trimmed.dropFirst(2)))
                if case .list(var items)? = fm.values[key] {
                    items.append(item)
                    fm.values[key] = .list(items)
                } else {
                    fm.values[key] = .list([item])
                }
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            currentKey = key
            if !fm.orderedKeys.contains(key) { fm.orderedKeys.append(key) }

            if value.isEmpty {
                fm.values[key] = .list([])
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                value.removeFirst(); value.removeLast()
                let items = value.split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty }
                fm.values[key] = .list(items)
            } else {
                fm.values[key] = .scalar(clean(value))
            }
        }

        let body = lines[(end + 1)...].joined(separator: "\n")
        // Drop keys that ended up as empty lists with no items
        fm.orderedKeys.removeAll { key in
            if case .list(let items)? = fm.values[key], items.isEmpty { fm.values[key] = nil; return true }
            return false
        }
        return (fm, body)
    }

    private static func clean(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v.removeFirst(); v.removeLast()
        }
        return v
    }
}

public enum FrontmatterValue {
    case scalar(String)
    case list([String])

    public var display: String {
        switch self {
        case .scalar(let s): return s
        case .list(let items): return items.joined(separator: ", ")
        }
    }
}
