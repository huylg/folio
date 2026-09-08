import AppKit
import XCTest
@testable import FolioKit

final class DocumentSelectionTests: XCTestCase {
    let metrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                  lineWidth: .comfortable, density: .airy)

    private func pane(_ markdown: String, columns: Int = 1) throws -> NativeDocumentView {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID()).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let pane = NativeDocumentView(metrics: metrics)
        pane.usesOpaqueBackground = true
        pane.frame = NSRect(x: 0, y: 0, width: paneWidth(forColumns: columns, metrics: metrics), height: 620)
        let window = TestWindow(contentRect: pane.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane
        window.orderBack(nil)
        pane.render(document: try MarkdownDocument(url: url), metrics: metrics)
        pane.layoutSubtreeIfNeeded()
        addTeardownBlock { window.orderOut(nil); try? FileManager.default.removeItem(at: url) }
        return pane
    }

    private func component(_ text: String, _ offset: Int) -> DocumentComponent {
        DocumentComponent(kind: .paragraph, content: .text(NSAttributedString(string: text)),
                          range: NSRange(location: offset, length: (text as NSString).length))
    }

    func testIndexClipboardAndAtomicSearchBoundaries() {
        let table = TableSpec(header: [.init(text: NSAttributedString(string: "Name")), .init(text: NSAttributedString(string: "Count"))],
            rows: [[.init(text: NSAttributedString(string: "Alpha")), .init(text: NSAttributedString(string: "12"))]], alignments: [])
        let fm = Frontmatter.parse("---\ntitle: Test\ntags: [swift, macOS]\n---").0
        let components = [component("Hello 👩🏽‍💻", 0),
            DocumentComponent(kind: .codeHeader, content: .code(label: "swift", source: "  let a = 1\n",
                language: "swift", lines: NSAttributedString(string: "  let a = 1\n")), range: NSRange(location: 40, length: 20)),
            DocumentComponent(kind: .table, content: .widget(.table(table)), range: NSRange(location: 60, length: 1)),
            DocumentComponent(kind: .frontmatter, content: .widget(.frontmatter(fm)), range: NSRange(location: 62, length: 1)),
            DocumentComponent(kind: .thematicBreak, content: .rule, range: NSRange(location: 64, length: 1))]
        let index = DocumentTextIndex(components: components)
        XCTAssertEqual(index.copyText(in: index.fullRange),
            "Hello 👩🏽‍💻\n\n  let a = 1\n\n\nName\tCount\nAlpha\t12\n\ntitle: Test\ntags: swift, macOS\n\n---")
        XCTAssertEqual(index.segment(component: 1, part: .body)?.range.location, ("Hello 👩🏽‍💻\n\n" as NSString).length)
        let cell = index.segment(component: 2, part: .cell(row: 1, column: 0))!.range
        XCTAssertEqual(index.copyText(in: NSRange(location: cell.location + 1, length: 3)), "lph")
        XCTAssertFalse(index.isSearchable(index.fullRange))
        XCTAssertTrue(index.isSearchable(cell))
        XCTAssertFalse((index.string as String).contains("---"))
    }

    func testCopyAllDoesNotCreateOffscreenViewsOrMeasure() throws {
        let pane = try pane("# Book\n\n" + (1...500).map { "Paragraph \($0) with text to select." }.joined(separator: "\n\n"), columns: 2)
        let stack = pane.stackView
        let count = stack.subviews.count, measures = stack.measuredComponents
        let configurations = TextComponentView.configureCount
        stack.selectAll(nil)
        stack.copy(nil)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("Paragraph 500") == true)
        XCTAssertEqual(stack.subviews.count, count)
        XCTAssertEqual(stack.measuredComponents, measures)
        XCTAssertEqual(TextComponentView.configureCount, configurations)
        let selection = stack.selectionController.selectedRange
        pane.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 4000))
        stack.populateVisible()
        XCTAssertEqual(stack.selectionController.selectedRange, selection)
        pane.window?.setContentSize(NSSize(width: pane.frame.width + 100, height: 620))
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(stack.selectionController.selectedRange, selection)
    }

    func testAllTextualWidgetsHaveSelectableGeometry() throws {
        let pane = try pane("""
        ---
        title: Metadata title
        tags: [swift, reader]
        ---
        # Heading

        Prose paragraph.

        | Name | Count |
        | --- | ---: |
        | Alpha | 12 |

        ```swift
        let value = 42
        ```

        <div>Visible HTML</div>
        """)
        let stack = pane.stackView, index = stack.selectionController.index
        for needle in ["Metadata title", "swift, reader", "Prose paragraph.", "Alpha", "let value = 42", "Visible HTML"] {
            let range = index.string.range(of: needle)
            XCTAssertNotEqual(range.location, NSNotFound, needle)
            stack.revealSelection(range)
            XCTAssertFalse(stack.selectionRects(range).isEmpty, needle)
        }
        let alpha = index.string.range(of: "Alpha")
        let surface = try XCTUnwrap(stack.surface(containing: alpha.location, reveal: true))
        let owner = try XCTUnwrap(surface.view)
        let rect = try XCTUnwrap(surface.rects(for: NSRange(location: alpha.location, length: 1)).first)
        let point = owner.convert(NSPoint(x: rect.minX + 0.1, y: rect.midY), to: stack)
        XCTAssertEqual(stack.selectionOffset(at: point), alpha.location)
    }

    private func mouse(_ type: NSEvent.EventType, stack: DocumentStackView, point: NSPoint, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: stack.convert(point, to: nil), modifierFlags: flags,
            timestamp: 0, windowNumber: stack.window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func point(_ offset: Int, stack: DocumentStackView) throws -> NSPoint {
        let surface = try XCTUnwrap(stack.surface(containing: offset, reveal: true))
        let view = try XCTUnwrap(surface.view)
        let rect = try XCTUnwrap(surface.rects(for: NSRange(location: offset, length: 1)).first)
        return view.convert(NSPoint(x: rect.minX + 0.1, y: rect.midY), to: stack)
    }

    func testPointerDragAcrossBlocksAndReverse() throws {
        let pane = try pane("# Heading\n\nFirst paragraph here.\n\nSecond paragraph there.")
        let stack = pane.stackView
        let text = stack.selectionController.index.string
        let a = text.range(of: "paragraph here").location
        let b = text.range(of: "paragraph there").location
        let first = try point(a, stack: stack), last = try point(b, stack: stack)
        stack.mouseDown(with: mouse(.leftMouseDown, stack: stack, point: first))
        XCTAssertEqual(stack.selectionController.selectedRange.length, 0)
        stack.mouseDragged(with: mouse(.leftMouseDragged, stack: stack, point: last))
        stack.mouseUp(with: mouse(.leftMouseUp, stack: stack, point: last))
        XCTAssertEqual(stack.selectionController.selectedRange, NSRange(location: a, length: b - a))
        XCTAssertEqual(stack.selectionController.selectedText, "paragraph here.\n\nSecond ")
        stack.mouseDown(with: mouse(.leftMouseDown, stack: stack, point: last))
        stack.mouseDragged(with: mouse(.leftMouseDragged, stack: stack, point: first))
        stack.mouseUp(with: mouse(.leftMouseUp, stack: stack, point: first))
        XCTAssertEqual(stack.selectionController.selectedRange, NSRange(location: a, length: b - a))
    }

    func testWordSelectionShiftClickAndUnicodeKeyboard() throws {
        let pane = try pane("# Heading\n\nAlpha 👩🏽‍💻 é 中文 שלום Beta.")
        let stack = pane.stackView, text = stack.selectionController.index.string
        let alpha = text.range(of: "Alpha"), emoji = text.range(of: "👩🏽‍💻")
        let point = try point(alpha.location + 2, stack: stack)
        stack.mouseDown(with: mouse(.leftMouseDown, stack: stack, point: point, clicks: 2))
        stack.mouseUp(with: mouse(.leftMouseUp, stack: stack, point: point, clicks: 2))
        XCTAssertEqual(stack.selectionController.selectedText, "Alpha")
        stack.selectionController.setRange(NSRange(location: emoji.location, length: 0))
        stack.moveRightAndModifySelection(nil)
        XCTAssertEqual(stack.selectionController.selectedText, "👩🏽‍💻")
        stack.moveLeftAndModifySelection(nil)
        XCTAssertEqual(stack.selectionController.selectedRange.length, 0)
        stack.moveToEndOfDocumentAndModifySelection(nil)
        XCTAssertEqual(NSMaxRange(stack.selectionController.selectedRange), text.length)
    }

    func testTimedAutoscrollDoesNotNeedMouseMovedEvents() throws {
        let pane = try pane("# Heading\n\n" + (1...100).map { "Paragraph \($0)." }.joined(separator: "\n\n"))
        let stack = pane.stackView
        let start = try point(stack.selectionController.index.string.range(of: "Paragraph 1.").location, stack: stack)
        stack.mouseDown(with: mouse(.leftMouseDown, stack: stack, point: start))
        let outside = NSPoint(x: start.x, y: stack.visibleRect.maxY + 50)
        stack.mouseDragged(with: mouse(.leftMouseDragged, stack: stack, point: outside))
        let before = pane.scrollView.contentView.bounds.minY
        XCTAssertTrue(waitUntil { pane.scrollView.contentView.bounds.minY > before + 10 })
        XCTAssertGreaterThan(stack.selectionController.selectedRange.length, 0)
        stack.endSelectionDrag()
        let stopped = pane.scrollView.contentView.bounds.minY
        stack.autoscrollSelection()
        XCTAssertEqual(pane.scrollView.contentView.bounds.minY, stopped)
    }

    func testFindOffscreenAndNoHiddenSource() throws {
        let pane = try pane("# Heading\n\n" + (1...100).map { "Paragraph \($0)." }.joined(separator: "\n\n") + "\n\n![PrivateAlt](private-image.png)")
        let stack = pane.stackView, controller = pane.findController
        XCTAssertFalse(controller.string.contains("private-image"))
        XCTAssertTrue(controller.string.contains("PrivateAlt"), "the visible caption remains searchable")
        stack.selectionController.setRange(stack.selectionController.index.string.range(of: "Paragraph 99."))
        controller.finder.performAction(.setSearchString)
        stack.selectionController.setRange(NSRange(location: 0, length: 0))
        controller.finder.performAction(.nextMatch)
        XCTAssertTrue(waitUntil { stack.selectionController.selectedText == "Paragraph 99." })
        XCTAssertGreaterThan(pane.scrollView.contentView.bounds.minY, 0)
        XCTAssertFalse(stack.selectionRects(stack.selectionController.selectedRange).isEmpty)
        XCTAssertLessThan(stack.subviews.count, 80)
        XCTAssertFalse(controller.isEditable)
        XCTAssertFalse(controller.validate(.replaceAll))
    }

    func testReplacementAndAccessibilityShareSelection() throws {
        let pane = try pane("# Heading\n\nA paragraph.")
        let stack = pane.stackView, index = stack.selectionController.index
        let range = index.string.range(of: "paragraph")
        stack.setAccessibilitySelectedTextRange(range)
        XCTAssertEqual(stack.accessibilitySelectedText(), "paragraph")
        XCTAssertFalse(stack.accessibilityFrame(for: range).isEmpty)
        stack.selectionController.replace(DocumentTextIndex(components: stack.components), identity: stack.runContext?.documentURL)
        XCTAssertEqual(stack.selectionController.selectedRange, range)
        stack.selectionController.replace(DocumentTextIndex(components: [component("Changed", 0)]), identity: nil)
        XCTAssertEqual(stack.selectionController.selectedRange.length, 0)
        XCTAssertEqual(pane.findController.string, "Changed")
    }

    func testSplitTableHeadersAndReadingOrderAcrossColumns() throws {
        let markdown = "# Table\n\n| Name | Count |\n| --- | ---: |\n"
            + (1...70).map { "| Row \($0) | \($0) |" }.joined(separator: "\n")
            + "\n\nAfter the table."
        let pane = try pane(markdown, columns: 2)
        let stack = pane.stackView, index = stack.selectionController.index
        XCTAssertEqual(stack.columnCount, 2)
        let component = try XCTUnwrap(stack.components.firstIndex { if case .widget(.table) = $0.content { return true }; return false })
        XCTAssertGreaterThan(stack.placementCount(ofComponent: component), 2)
        let row = index.string.range(of: "Row 65")
        stack.revealSelection(row)
        let headers = stack.selectionSurfaces().filter { if case .cell(row: 0, column: _) = $0.part { return true }; return false }
        XCTAssertTrue(headers.allSatisfy { $0.range.location == index.segment(component: component, part: $0.part)?.range.location })
        XCTAssertFalse(stack.selectionRects(row).isEmpty)
        stack.selectAll(nil)
        XCTAssertEqual(stack.selectionController.selectedText.components(separatedBy: "Name\tCount").count - 1, 1)
        XCTAssertTrue(stack.selectionController.selectedText.contains("Row 65\t65\nRow 66\t66"))

        let from = index.string.range(of: "Row 1\t").location
        let to = index.string.range(of: "Row 25\t").location
        let first = try point(from, stack: stack), last = try point(to, stack: stack)
        stack.mouseDown(with: mouse(.leftMouseDown, stack: stack, point: first))
        stack.mouseDragged(with: mouse(.leftMouseDragged, stack: stack, point: last))
        stack.mouseUp(with: mouse(.leftMouseUp, stack: stack, point: last))
        XCTAssertEqual(stack.selectionController.selectedRange, NSRange(location: from, length: to - from))
    }

    func testKeyboardMovesAcrossParagraphsAndWrappedLines() throws {
        let pane = try pane("# Heading\n\nAlpha starts here.\n\nBeta follows here.")
        let stack = pane.stackView, text = stack.selectionController.index.string
        let alpha = text.range(of: "Alpha"), beta = text.range(of: "Beta")
        stack.selectionController.setRange(NSRange(location: alpha.location, length: 0))
        stack.moveDownAndModifySelection(nil)
        XCTAssertEqual(stack.selectionController.focus, beta.location)
        stack.moveUpAndModifySelection(nil)
        XCTAssertEqual(stack.selectionController.focus, alpha.location)
        stack.moveToEndOfLineAndModifySelection(nil)
        XCTAssertEqual(stack.selectionController.selectedText, "Alpha starts here.")
    }

    func testFindBarReflowsAndKeepsSelection() throws {
        let pane = try pane("# Heading\n\n" + (1...80).map { "Paragraph \($0)." }.joined(separator: "\n\n"), columns: 2)
        let stack = pane.stackView
        let range = stack.selectionController.index.string.range(of: "Paragraph 20.")
        stack.selectionController.setRange(range)
        let before = stack.spreadHeight
        pane.findController.perform(NSMenuItem.findAction(.showFindInterface))
        XCTAssertTrue(pane.scrollView.isFindBarVisible)
        XCTAssertTrue(waitUntil { stack.spreadHeight < before },
            "bar=\(String(describing: pane.scrollView.findBarView?.frame)) clip=\(pane.scrollView.contentView.frame) insets=\(pane.scrollView.contentInsets)")
        XCTAssertEqual(stack.selectionController.selectedRange, range)
        pane.findController.perform(NSMenuItem.findAction(.hideFindInterface))
        XCTAssertFalse(pane.scrollView.isFindBarVisible)
        XCTAssertTrue(waitUntil { abs(stack.spreadHeight - before) < 1 })
    }

    func testPreviewGetsIndependentSelectionAndForwardsFind() throws {
        let pane = try pane("# Main\n\nMain document text.")
        let window = try XCTUnwrap(pane.window)
        window.makeKey()
        window.makeFirstResponder(pane.stackView)
        pane.stackView.selectAll(nil)
        let mainSelection = pane.stackView.selectionController.selectedRange
        let preview = PeekPreviewPanel()
        preview.onDismissRequest = { [weak preview] in preview?.hide() }
        let oldAppear = PeekPreviewPanel.appearDuration, oldFade = PeekPreviewPanel.fadeOutDuration
        PeekPreviewPanel.appearDuration = 0; PeekPreviewPanel.fadeOutDuration = 0
        defer { preview.hide(); PeekPreviewPanel.appearDuration = oldAppear; PeekPreviewPanel.fadeOutDuration = oldFade }
        let content = [component("Preview first paragraph.", 0), component("Preview second paragraph.", 30)]
        preview.show(SectionPreview(components: content, metrics: metrics), title: "Preview",
            anchoredTo: window.convertToScreen(NSRect(x: 100, y: 100, width: 60, height: 30)), in: window)
        func stack(in view: NSView) -> DocumentStackView? {
            (view as? DocumentStackView) ?? view.subviews.lazy.compactMap { stack(in: $0) }.first
        }
        let panel = try XCTUnwrap(window.childWindows?.last)
        let previewStack = try XCTUnwrap(panel.contentView.flatMap { stack(in: $0) })
        XCTAssertFalse(panel.isKeyWindow, "hover must leave keyboard focus in the main window")
        let start = try point(0, stack: previewStack)
        previewStack.mouseDown(with: mouse(.leftMouseDown, stack: previewStack, point: start))
        previewStack.mouseUp(with: mouse(.leftMouseUp, stack: previewStack, point: start))
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(preview.isInteracting)
        previewStack.selectAll(nil)
        previewStack.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Preview first paragraph.\n\nPreview second paragraph.")
        XCTAssertEqual(pane.stackView.selectionController.selectedRange, mainSelection)
        previewStack.performTextFinderAction(NSMenuItem.findAction(.showFindInterface))
        XCTAssertFalse(preview.isShown)
        XCTAssertTrue(pane.scrollView.isFindBarVisible)
    }

    func testLinkDragDoesNotOpenAndClickDoes() throws {
        final class Links: ComponentLinkDelegate {
            var destinations: [String] = []
            func component(_ view: NSView, didClickLink destination: String) { destinations.append(destination) }
        }
        let pane = try pane("# Heading\n\nA [linked word](https://example.com) then text.\n\nAnother paragraph.")
        let stack = pane.stackView, links = Links()
        stack.linkDelegate = links
        let text = stack.selectionController.index.string
        let start = try point(text.range(of: "linked word").location + 1, stack: stack)
        let end = try point(text.range(of: "Another").location + 4, stack: stack)
        stack.mouseDown(with: mouse(.leftMouseDown, stack: stack, point: start))
        stack.mouseDragged(with: mouse(.leftMouseDragged, stack: stack, point: end))
        stack.mouseUp(with: mouse(.leftMouseUp, stack: stack, point: end))
        XCTAssertTrue(links.destinations.isEmpty)
        stack.mouseDown(with: mouse(.leftMouseDown, stack: stack, point: start))
        stack.mouseUp(with: mouse(.leftMouseUp, stack: stack, point: start))
        XCTAssertEqual(links.destinations, ["https://example.com"])
    }

    func testSelectionAndFindRenderWithoutRemeasuring() throws {
        let markdown = """
        ---
        title: Selectable document
        tags: [native, markdown]
        ---
        # A continuous selection

        Select text across paragraphs, tables and code. A second sentence wraps across the reading measure.

        | Name | Count |
        | --- | ---: |
        | First item | 12 |
        | Another longer item | 1400 |

        ```swift
        let message = "Hello, Folio"
        print(message)
        ```

        ## Next section

        Selection follows the reading order across columns.

        <div>HTML source is selectable too.</div>
        """
        for columns in [1, 2, 3] {
            let pane = try pane(markdown, columns: columns)
            let stack = pane.stackView
            stack.selectAll(nil)
            stack.selectionController.isActive = true
            let measured = stack.measuredComponents, configured = TextComponentView.configureCount
            let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
            pane.cacheDisplay(in: pane.bounds, to: bitmap)
            XCTAssertEqual(stack.measuredComponents, measured)
            XCTAssertEqual(TextComponentView.configureCount, configured)
            if let path = ProcessInfo.processInfo.environment["FOLIO_SELECTION_SNAPSHOT"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(columns).png"))
            }
            let query = stack.selectionController.index.string.range(of: "text")
            stack.selectionController.setRange(query)
            pane.findController.perform(NSMenuItem.findAction(.setSearchString))
            pane.findController.perform(NSMenuItem.findAction(.showFindInterface))
            XCTAssertTrue(waitUntil { !pane.findController.finder.incrementalMatchRanges.isEmpty })
            let found = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
            pane.cacheDisplay(in: pane.bounds, to: found)
            if let path = ProcessInfo.processInfo.environment["FOLIO_SELECTION_SNAPSHOT"] {
                try found.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(columns)-find.png"))
            }
            pane.findController.perform(NSMenuItem.findAction(.hideFindInterface))
        }
    }

    func testAtomicClickAndConsoleCommandsStaySeparate() throws {
        let pane = try pane("# Heading\n\n![Caption](missing.png)\n\n```bash\necho hello\n```\n\nTail text.")
        let stack = pane.stackView, index = stack.selectionController.index
        let object = try XCTUnwrap(index.segments.first { $0.replacement != nil })
        let start = try point(object.range.location, stack: stack)
        stack.mouseDown(with: mouse(.leftMouseDown, stack: stack, point: start))
        stack.mouseUp(with: mouse(.leftMouseUp, stack: stack, point: start))
        XCTAssertEqual(stack.selectionController.selectedText, "![Caption](missing.png)")
        XCTAssertFalse(pane.findController.validate(.setSearchString))
        let card = try XCTUnwrap(stack.subviews.compactMap { $0 as? CodeComponentView }.first)
        let button = try XCTUnwrap(card.runButton)
        let buttonPoint = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: stack.superview)
        XCTAssertTrue(stack.hitTest(buttonPoint) === button)
        let saved = stack.selectionController.selectedRange
        let local = TextComponentView()
        local.configure(with: NSAttributedString(string: "Local console text"), kind: .paragraph)
        local.selectAll(nil)
        local.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Local console text")
        XCTAssertEqual(stack.selectionController.selectedRange, saved)
        XCTAssertFalse((index.string as String).contains("Last edited"))
    }

    func testIncrementalFindAndMenuValidation() throws {
        let pane = try pane("# Heading\n\nNeedle alpha.\n\nNeedle beta.\n\nTail.")
        let stack = pane.stackView, controller = pane.findController
        pane.window?.makeKey()
        pane.window?.makeFirstResponder(stack)
        let query = stack.selectionController.index.string.range(of: "Needle")
        stack.selectionController.setRange(query)
        XCTAssertTrue(controller.validate(.setSearchString), "set search string validation")
        controller.perform(NSMenuItem.findAction(.setSearchString))
        controller.perform(NSMenuItem.findAction(.showFindInterface))
        XCTAssertTrue(waitUntil { controller.finder.incrementalMatchRanges.count == 2 })
        XCTAssertEqual(stack.selectionController.matchRanges.count, 2)
        stack.selectionController.setRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.validate(.nextMatch), "next match validation, ranges=\(controller.finder.incrementalMatchRanges)")
        controller.perform(NSMenuItem.findAction(.nextMatch))
        XCTAssertTrue(waitUntil { stack.selectionController.selectedRange == query })
        controller.perform(NSMenuItem.findAction(.nextMatch))
        XCTAssertTrue(waitUntil { stack.selectionController.selectedRange.location > query.location })
        controller.perform(NSMenuItem.findAction(.previousMatch))
        XCTAssertTrue(waitUntil { stack.selectionController.selectedRange == query })
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        XCTAssertTrue(stack.validateUserInterfaceItem(item))
        stack.selectionController.clear()
        XCTAssertFalse(stack.validateUserInterfaceItem(item))
        XCTAssertFalse(stack.validateUserInterfaceItem(NSMenuItem.findAction(.replaceAll)))
        controller.perform(NSMenuItem.findAction(.hideFindInterface))
    }

    func testAccessibleTableSelectionUsesLocalRange() throws {
        let pane = try pane("# Table\n\n| Key | Value |\n| --- | --- |\n| Alpha | Beta |")
        let stack = pane.stackView
        let range = stack.selectionController.index.string.range(of: "Alpha")
        let surface = try XCTUnwrap(stack.surface(containing: range.location, reveal: true))
        let element = surface.accessibilityElement
        element.setAccessibilitySelectedTextRange(NSRange(location: 1, length: 3))
        XCTAssertEqual(stack.selectionController.selectedText, "lph")
        XCTAssertEqual(element.accessibilitySelectedTextRange(), NSRange(location: 1, length: 3))
        XCTAssertFalse(element.accessibilityFrame().isEmpty)
    }
}
