import AppKit
@testable import FolioKit

/// A `BlockHost` that records what a widget asked it to do.
///
/// Existing widget tests pass `host: nil`, which is fine for geometry but says nothing about the
/// copy button or about how many times a layout was actually computed.
final class RecordingHost: BlockHost {
    var blockMetrics: DocumentMetrics
    let sizeCache = BlockSizeCache()
    let diagramLayouts = DiagramLayoutCache()
    var pendingWorkCount = 0

    private(set) var opened: [String] = []
    private(set) var copied: [String] = []

    init(metrics: DocumentMetrics = testMetrics) {
        self.blockMetrics = metrics
    }

    func blockRequestsOpen(_ destination: String) { opened.append(destination) }
    func blockRequestsCopy(_ text: String) { copied.append(text) }
}
