import AppKit

/// Carries a widget's payload in the built attributed string.
///
/// The attributed string is no longer what the reader looks at — components are — but it is
/// still the document's canonical text: anchors, the outline probe, the structural dump, and
/// copy all work in character space. So a widget block still occupies one attachment
/// character, and this is what hangs the payload off it.
///
/// Deliberately *not* a view-vending attachment. The previous version implemented
/// `viewProvider` and `attachmentBounds`, and everything painful about the old pane grew from
/// there: heights had to be pre-seeded into a cache because AppKit measures an attachment
/// before its view exists, and a widget's view could only be as wide as the line fragment it
/// sat in.
public final class BlockPayloadAttachment: NSTextAttachment, BlockPayloadCarrying {
    public let payload: BlockPayload

    public init(payload: BlockPayload) {
        self.payload = payload
        super.init(data: nil, ofType: nil)
        bounds = .zero
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}
