import AppKit

/// What the sidebar's peek card needs in order to draw a section: the document's own
/// components, and the metrics they were built against.
public struct SectionPreview {
    public let components: [DocumentComponent]
    public let metrics: DocumentMetrics
    /// Where a shell block in the card runs, and whose session store its consoles share.
    /// The current document's own context makes a run started in the card appear on the same
    /// block in the reading pane; a cross-file peek gets a throwaway store of its own; nil
    /// leaves the Run button inert.
    public let runContext: RunContext?

    public init(components: [DocumentComponent], metrics: DocumentMetrics,
                runContext: RunContext? = nil) {
        self.components = components
        self.metrics = metrics
        self.runContext = runContext
    }
}

/// Picks the components the peek card shows for one outline entry.
///
/// A slice of the built document's own components, handed to the same `DocumentStackView` the
/// reading pane uses — so a table in the card is the table view, a diagram is the diagram, and
/// a code block keeps its highlighting and its header.
///
/// It used to flatten the section into a single attributed string instead, which could not
/// work for anything but prose: a widget lives in `built.attributed` as an attachment
/// character whose payload rides on the attachment, so a flattened slice drew every table,
/// equation, diagram and image as a blank glyph. The card papered over that by substituting a
/// line of text naming the block — "Table · 3 columns" — which is a second renderer with its
/// own idea of what a document looks like. Reusing the components deletes it.
public enum SectionPreviewBuilder {

    /// Safety bounds, not the card's size: the card scrolls, so these only stop a giant
    /// section from being measured and laid out whole for a peek.
    public static var componentLimit = 24
    public static var characterLimit = 6000

    /// The components a whole-document peek opens with: the front of the document, under the
    /// same caps as a section. The document's own heading stays in — unlike a section's, it is
    /// part of showing what the file is.
    public static func leadingComponents(in built: BuiltDocument) -> [DocumentComponent] {
        var result: [DocumentComponent] = []
        var characters = 0
        for component in built.components {
            guard result.count < componentLimit, characters < characterLimit else { break }
            result.append(component)
            characters += component.range.length
        }
        return result
    }

    /// The components under section `index`. Empty when the section has no body — the row
    /// already shows the title, so a card with nothing under it is not worth presenting.
    public static func components(
        forOutlineIndex index: Int, in built: BuiltDocument
    ) -> [DocumentComponent] {
        guard let section = built.sectionRange(forOutlineIndex: index) else { return [] }
        // The heading component is skipped: its text is the row the reader is pressing.
        let bodyStart = NSMaxRange(built.headings[index].range)
        let sectionEnd = NSMaxRange(section)

        var result: [DocumentComponent] = []
        var characters = 0
        for component in built.components {
            guard component.range.location >= bodyStart else { continue }
            // Components are ordered by location, so the first one past the section ends it.
            guard component.range.location < sectionEnd else { break }
            guard result.count < componentLimit, characters < characterLimit else { break }
            result.append(component)
            characters += component.range.length
        }
        return result
    }
}
