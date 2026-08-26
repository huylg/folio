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
    private(set) var ran: [String] = []
    private(set) var heightChanges: [NSView] = []

    /// Held instead of called, so a test can drive the "still running" state explicitly.
    private(set) var pendingRunCompletions: [(ProcessRunner.Output?) -> Void] = []
    /// The live-output channels of runs still pending, so a test can stream into them.
    private(set) var pendingRunOutputs: [(String) -> Void] = []

    init(metrics: DocumentMetrics = testMetrics) {
        self.blockMetrics = metrics
    }

    func blockRequestsOpen(_ destination: String) { opened.append(destination) }
    func blockRequestsCopy(_ text: String) { copied.append(text) }
    func blockRequestsRun(_ command: String,
                          onOutput: @escaping (String) -> Void,
                          completion: @escaping (ProcessRunner.Output?) -> Void) {
        ran.append(command)
        pendingRunOutputs.append(onOutput)
        pendingRunCompletions.append(completion)
    }
    func blockHeightDidChange(_ view: NSView) { heightChanges.append(view) }

    /// Streams a transcript-so-far into every pending run, as the pty would.
    func emitOutput(_ transcript: String) {
        pendingRunOutputs.forEach { $0(transcript) }
    }

    func finishPendingRuns(with result: ProcessRunner.Output? = nil) {
        let completions = pendingRunCompletions
        pendingRunCompletions = []
        pendingRunOutputs = []
        completions.forEach { $0(result) }
    }
}
