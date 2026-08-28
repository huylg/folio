import AppKit
import XCTest
@testable import FolioKit

/// Fixtures live next to the tests rather than in the sample vault, because two of them exist
/// purely to pin bugs and would be confusing content for a reader.
private func fixture(_ name: String) throws -> MarkdownDocument {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try MarkdownDocument(url: url)
}

/// The project's own sample document, used as the realistic end-to-end fixture.
private func sampleDocument() throws -> MarkdownDocument {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FolioKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
    return try MarkdownDocument(url: root
        .appendingPathComponent("sample-vault/Drafts")
        .appendingPathComponent("Sparse attention under bounded compute.md"))
}

private func build(_ document: MarkdownDocument) -> BuiltDocument {
    AttributedDocumentBuilder(
        document: document,
        metrics: DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                lineWidth: .comfortable, density: .airy)
    ).build()
}

final class HeadingIndexTests: XCTestCase {

    /// Regression for the outline highlight being off by one on any document that does not
    /// open with an H1.
    ///
    /// The old pipeline injected a synthesized `<h1>` that the scroll-spy counted but the
    /// outline did not contain, so every heading index was shifted by one. The synthesized
    /// title must never appear in `headings`.
    func testSynthesizedTitleIsNotCountedAsAHeading() throws {
        let document = try fixture("no-leading-h1.md")
        let built = build(document)

        XCTAssertFalse(document.outline.contains { $0.level == 1 },
                       "fixture should have no real H1")
        XCTAssertEqual(built.headings.count, document.outline.count,
                       "headings must be index-aligned with outline")
        for (index, heading) in built.headings.enumerated() {
            XCTAssertEqual(heading.outlineIndex, index,
                           "headings[\(index)] points at outline[\(heading.outlineIndex)]")
        }

        // A title is still rendered — it just isn't a heading for navigation purposes.
        let kinds = blockKinds(in: built)
        XCTAssertTrue(kinds.contains(.title), "no synthesized title was rendered")
    }

    /// Regression for the outline highlight being misaligned on documents containing h5 or h6.
    /// The old scroll-spy enumerated only h1–h4 while the outline held every level.
    func testEveryHeadingLevelIsTracked() throws {
        let document = try fixture("deep-headings.md")
        let built = build(document)

        XCTAssertEqual(document.outline.count, 7, "fixture has h1 through h6 plus a second h2")
        XCTAssertEqual(built.headings.count, document.outline.count)
        XCTAssertEqual(built.headings.map(\.level), [1, 2, 3, 4, 5, 6, 2],
                       "h5 and h6 must be tracked, not dropped")
    }

    /// The status bar's "Section N of M" used to take N from JavaScript and M from
    /// `DocumentStats`, computed by different rules, so the two could disagree.
    func testSectionCountMatchesDocumentStats() throws {
        for name in ["deep-headings.md", "no-leading-h1.md"] {
            let document = try fixture(name)
            let built = build(document)
            let expected = document.outline.filter { $0.level <= 2 }.count
            XCTAssertEqual(built.sectionIndices.count, expected, "\(name)")
        }
    }

    /// Every outline anchor must resolve, or an outline click or `#fragment` link goes nowhere.
    func testEveryOutlineAnchorResolves() throws {
        let document = try fixture("deep-headings.md")
        let built = build(document)
        for entry in document.outline {
            XCTAssertNotNil(built.anchors[entry.anchor], "anchor '\(entry.anchor)' unresolved")
        }
    }

    func testHeadingLookupIsMonotonic() throws {
        let document = try fixture("deep-headings.md")
        let built = build(document)
        var previous = -1
        for heading in built.headings {
            let found = built.headingIndex(at: heading.range.location)
            XCTAssertNotNil(found)
            XCTAssertGreaterThan(found!, previous)
            previous = found!
        }
    }

    private func blockKinds(in built: BuiltDocument) -> Set<BlockKind> {
        Set(built.blocks.map(\.kind))
    }
}

final class LinkRouterTests: XCTestCase {

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// The web view resolved relative paths for free via `baseURL:`. Natively this is explicit,
    /// and `URL(string:)` is the trap: it returns nil for any path containing a space, and the
    /// sample vault has exactly such a filename.
    func testResolvesRelativePathContainingASpace() {
        let target = LinkRouter.resolve("spaced link.md", relativeTo: fixturesDirectory)
        guard case .markdown(let url, let fragment) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.lastPathComponent, "spaced link.md")
        XCTAssertNil(fragment)
        // The resolved URL must be absolute and actually exist — a schemeless URL would carry
        // a relative path that resolves against the process working directory instead.
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testResolvesPercentEncodedPath() {
        let target = LinkRouter.resolve("spaced%20link.md", relativeTo: fixturesDirectory)
        guard case .markdown(let url, _) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.lastPathComponent, "spaced link.md")
    }

    /// `foo.md#section` used to lose its fragment, so such a link opened the file at the top.
    func testCarriesFragmentAcrossFiles() {
        let target = LinkRouter.resolve("deep-headings.md#three", relativeTo: fixturesDirectory)
        guard case .markdown(_, let fragment) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(fragment, "three")
    }

    func testClassifiesSchemesAndFragments() {
        XCTAssertEqual(LinkRouter.resolve("#anchor", relativeTo: fixturesDirectory),
                       .fragment("anchor"))

        for scheme in ["http://example.com", "https://example.com/a?b=c",
                       "mailto:someone@example.com"] {
            guard case .external = LinkRouter.resolve(scheme, relativeTo: fixturesDirectory) else {
                return XCTFail("\(scheme) should be external")
            }
        }
    }

    /// The web view silently 404'd a broken relative link; now it is reported.
    func testMissingFileIsReported() {
        guard case .missing = LinkRouter.resolve("nope.md", relativeTo: fixturesDirectory) else {
            return XCTFail("a nonexistent path should classify as missing")
        }
    }

    /// A remote URL must never be mistaken for a relative filename.
    func testRemoteURLIsNotTreatedAsAPath() {
        let target = LinkRouter.resolve("https://example.com/x.md", relativeTo: fixturesDirectory)
        guard case .external = target else {
            return XCTFail("expected external, got \(target)")
        }
    }

    // MARK: Root-absolute links

    /// A base that is NOT where the target lives, proving `/…` ignores it and uses the root.
    private var elsewhere: URL {
        fixturesDirectory.appendingPathComponent("elsewhere")
    }

    func testLeadingSlashResolvesAgainstTheRootNotTheBase() {
        let target = LinkRouter.resolve("/deep-headings.md", relativeTo: elsewhere,
                                        root: fixturesDirectory)
        guard case .markdown(let url, let fragment) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.standardizedFileURL.path,
                       fixturesDirectory.appendingPathComponent("deep-headings.md")
                           .standardizedFileURL.path)
        XCTAssertNil(fragment)
    }

    func testRootAbsoluteLinkCarriesItsFragment() {
        let target = LinkRouter.resolve("/deep-headings.md#three", relativeTo: elsewhere,
                                        root: fixturesDirectory)
        guard case .markdown(_, let fragment) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(fragment, "three")
    }

    func testRootAbsoluteLinkPercentDecodes() {
        let target = LinkRouter.resolve("/spaced%20link.md", relativeTo: elsewhere,
                                        root: fixturesDirectory)
        guard case .markdown(let url, _) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.lastPathComponent, "spaced link.md")
    }

    func testBrokenRootAbsoluteLinkIsMissing() {
        guard case .missing = LinkRouter.resolve("/nope.md", relativeTo: fixturesDirectory,
                                                 root: fixturesDirectory) else {
            return XCTFail("a nonexistent root-absolute path should classify as missing")
        }
    }

    func testRelativeLinkPrefersTheBaseOverTheRoot() {
        let bogusRoot = URL(fileURLWithPath: "/definitely/not/here")
        let target = LinkRouter.resolve("deep-headings.md", relativeTo: fixturesDirectory,
                                        root: bogusRoot)
        guard case .markdown(let url, _) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.lastPathComponent, "deep-headings.md")
    }

    /// A document living outside the tree it describes — a Claude plan in `~/.claude/plans` —
    /// writes its relative paths against the root, so a miss beside the document retries there.
    func testRelativeLinkMissingAtTheBaseFallsBackToTheRoot() {
        let target = LinkRouter.resolve("deep-headings.md", relativeTo: elsewhere,
                                        root: fixturesDirectory)
        guard case .markdown(let url, _) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.standardizedFileURL.path,
                       fixturesDirectory.appendingPathComponent("deep-headings.md")
                           .standardizedFileURL.path)
    }

    /// Agent plans link with a line suffix — "src/voucher.py:1043" — which names the file.
    func testTrailingLineNumberIsStripped() {
        let target = LinkRouter.resolve("deep-headings.md:12", relativeTo: fixturesDirectory)
        guard case .markdown(let url, _) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.lastPathComponent, "deep-headings.md")
    }

    func testTrailingLineAndColumnAreStripped() {
        let target = LinkRouter.resolve("deep-headings.md:12:4", relativeTo: elsewhere,
                                        root: fixturesDirectory)
        guard case .markdown(let url, _) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.standardizedFileURL.path,
                       fixturesDirectory.appendingPathComponent("deep-headings.md")
                           .standardizedFileURL.path)
    }

    func testRelativeLinkMissingAtBaseAndRootIsMissing() {
        guard case .missing = LinkRouter.resolve("nope.md", relativeTo: elsewhere,
                                                 root: fixturesDirectory) else {
            return XCTFail("a path missing at both base and root should classify as missing")
        }
    }

    /// Without a root, a leading slash keeps meaning the filesystem, as it always did.
    func testAbsolutePathWithoutARootKeepsFilesystemSemantics() {
        let target = LinkRouter.resolve("/bin/sh", relativeTo: fixturesDirectory)
        guard case .file(let url) = target else {
            return XCTFail("expected a file target, got \(target)")
        }
        XCTAssertEqual(url.path, "/bin/sh")
    }

    /// "//x" must not fall back to filesystem-absolute and escape the root.
    func testDoubledSlashesStayInsideTheRoot() {
        let target = LinkRouter.resolve("//deep-headings.md", relativeTo: elsewhere,
                                        root: fixturesDirectory)
        guard case .markdown(let url, _) = target else {
            return XCTFail("expected a markdown target, got \(target)")
        }
        XCTAssertEqual(url.standardizedFileURL.path,
                       fixturesDirectory.appendingPathComponent("deep-headings.md")
                           .standardizedFileURL.path)
    }
}

final class BuilderStructureTests: XCTestCase {

    /// A code fence must produce a header paragraph plus one paragraph per line, all real text
    /// so Find can reach it — not an attachment.
    func testCodeIsRealTextWithAHeaderParagraph() throws {
        let document = try sampleDocument()
        let built = build(document)
        let kinds = built.blocks.map(\.kind)

        XCTAssertTrue(kinds.contains(.codeHeader), "no code card header emitted")
        XCTAssertTrue(kinds.contains { if case .codeLine = $0 { return true } else { return false } },
                      "no code lines emitted")
        XCTAssertTrue(built.plainText.contains("def route(q, k, budget):"),
                      "code body is not in the text stream, so Find cannot see it")
    }

    /// Tables, math, diagrams, the frontmatter card, and images are the only blocks rendered by
    /// a widget component. Everything else stays text, and stays selectable as text.
    func testOnlyExpectedBlocksBecomeWidgets() throws {
        let document = try sampleDocument()
        let built = build(document)
        var widgets = 0
        for component in built.components {
            guard case .widget = component.content else { continue }
            widgets += 1
            switch component.kind {
            case .table, .math, .diagram, .frontmatter, .image:
                continue
            default:
                XCTFail("\(component.kind) should not be a widget component")
            }
        }
        XCTAssertGreaterThan(widgets, 0, "fixture should contain block widgets")
    }

    /// A list is one component, not one per item, and a fenced block is one component, not a
    /// header plus a paragraph per line. Selection is per component, so this is what decides
    /// whether a reader can select a whole list.
    func testContainersBecomeOneComponentEach() throws {
        let document = try sampleDocument()
        let built = build(document)

        let lists = built.components.filter { if case .listItem = $0.kind { return true } else { return false } }
        XCTAssertFalse(lists.isEmpty, "fixture should contain a list")
        for list in lists {
            guard case .text(let attributed) = list.content else {
                return XCTFail("a list should be a text component")
            }
            XCTAssertTrue(attributed.string.contains("\n"),
                          "a multi-item list should be one component holding every item")
        }

        let code = built.components.filter { if case .code = $0.content { return true } else { return false } }
        XCTAssertFalse(code.isEmpty, "fixture should contain a fenced code block")
        for card in code {
            guard case .code(_, let source, _, let lines) = card.content else { return }
            XCTAssertGreaterThan(source.components(separatedBy: "\n").count, 1)
            XCTAssertGreaterThan(lines.length, 0, "the card has no highlighted text")
        }
    }

    /// Every attachment carries a plain-text substitute, so ⌘A ⌘C yields readable Markdown
    /// rather than a run of object-replacement characters.
    func testEveryAttachmentHasCopyText() throws {
        let document = try sampleDocument()
        let built = build(document)
        let full = NSRange(location: 0, length: built.attributed.length)
        var attachmentCount = 0
        built.attributed.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard value is BlockPayloadAttachment else { return }
            attachmentCount += 1
            let substitute = built.attributed.attribute(.folioCopyText, at: range.location,
                                                        effectiveRange: nil) as? String
            XCTAssertNotNil(substitute, "attachment at \(range) has no copy text")
        }
        XCTAssertGreaterThan(attachmentCount, 0)
    }

    /// Bold nested inside italic has to keep both. Applying an outer node's attributes to the
    /// range its children produced would overwrite the inner ones.
    func testNestedEmphasisComposes() throws {
        let source = "*outer **both** outer*"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nested-\(UUID().uuidString).md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let built = build(try MarkdownDocument(url: url))
        let text = built.attributed
        guard let range = text.string.range(of: "both") else { return XCTFail("missing text") }
        let index = NSRange(range, in: text.string).location
        guard let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont else {
            return XCTFail("no font on the nested run")
        }
        let traits = font.fontDescriptor.symbolicTraits
        XCTAssertTrue(traits.contains(.italic), "nested run lost italic")
        let name = font.fontDescriptor.postscriptName ?? font.fontName
        let isBold = traits.contains(.bold)
            || name.localizedCaseInsensitiveContains("semibold")
            || name.localizedCaseInsensitiveContains("bold")
        XCTAssertTrue(isBold, "nested run lost bold (font: \(name))")
    }
}

/// HTML comments are notes to the author, not content.
///
/// A comment-only block used to render as an `html` source card — a card in the reading flow
/// holding text that is invisible in every other renderer.
final class HTMLCommentTests: XCTestCase {

    private func components() throws -> [DocumentComponent] {
        build(try fixture("html-comments.md")).components
    }

    func testCommentOnlyBlocksAreDropped() throws {
        let cards = try components().compactMap { component -> String? in
            guard case .code(let label, let source, _, _) = component.content, label == "html"
            else { return nil }
            return source
        }
        for source in cards {
            XCTAssertFalse(BlockWalker.holdsOnlyComments(source),
                           "a comment-only block was rendered: \(source)")
        }
        XCTAssertFalse(cards.isEmpty, "the fixture's real markup should still be shown")
    }

    /// A block that also holds markup keeps its card, comments included: the card shows what the
    /// author wrote.
    func testBlocksWithRealMarkupSurvive() throws {
        let cards = try components().compactMap { component -> String? in
            guard case .code(let label, let source, _, _) = component.content, label == "html"
            else { return nil }
            return source
        }
        XCTAssertTrue(cards.contains { $0.contains("class=\"note\"") },
                      "a real HTML block was dropped")
        XCTAssertTrue(cards.contains { $0.contains("leading comment") && $0.contains("<div>") },
                      "a block mixing a comment and markup should keep both")
    }

    /// Inline comments never reach the text either.
    func testInlineCommentsAreNotRendered() throws {
        let text = build(try fixture("html-comments.md")).attributed.string
        XCTAssertFalse(text.contains("hidden"), "an inline comment leaked into the text")
        XCTAssertFalse(text.contains("PDF page"), "a block comment leaked into the text")
        XCTAssertTrue(text.contains("comment inside a paragraph"),
                      "the paragraph around an inline comment should survive")
    }

    func testCommentStrippingEdgeCases() {
        XCTAssertTrue(BlockWalker.holdsOnlyComments("<!-- a -->"))
        XCTAssertTrue(BlockWalker.holdsOnlyComments("  <!-- a -->\n<!-- b -->  "))
        // Unterminated: a parser swallows the rest of the block, and so do we.
        XCTAssertTrue(BlockWalker.holdsOnlyComments("<!-- never closed"))
        XCTAssertFalse(BlockWalker.holdsOnlyComments("<!-- a --><b>x</b>"))
        XCTAssertFalse(BlockWalker.holdsOnlyComments("<div/>"))
    }
}
