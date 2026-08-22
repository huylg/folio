import AppKit
import XCTest
@testable import FolioKit

final class UnconstrainedProbeWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class ZZProbeTests: XCTestCase {

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func document() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    private func settle(_ seconds: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    func testProbeGeometry() throws {
        print("PROBE screens:", NSScreen.screens.map { "frame=\($0.frame) visible=\($0.visibleFrame)" })
        print("PROBE main:", NSScreen.main.map { "\($0.frame)" } ?? "nil")

        for free in [false, true] {
            for size in [NSSize(width: 900, height: 700), NSSize(width: 1500, height: 800),
                         NSSize(width: 1600, height: 700)] {
                let view = NativeDocumentView(metrics: metrics)
                view.animatesNavigation = false
                view.frame = NSRect(origin: .zero, size: size)
                let rect = view.frame
                let mask: NSWindow.StyleMask = [.titled, .resizable]
                let window = free
                    ? UnconstrainedProbeWindow(contentRect: rect, styleMask: mask,
                                               backing: .buffered, defer: false)
                    : NSWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
                window.contentView = view
                window.orderBack(nil)
                view.render(document: try document(), metrics: metrics)
                view.layoutSubtreeIfNeeded()
                settle()
                print("PROBE free=\(free) asked \(size) content=\(view.frame.size)",
                      "columns=\(view.stackView.columnCount)",
                      "columnWidth=\(view.stackView.columnWidth)",
                      "spreads=\(view.stackView.spreadCount)",
                      "parking=\(view.stackView.trailingParkingSpace)")

                window.setContentSize(NSSize(width: size.width, height: 1000))
                view.layoutSubtreeIfNeeded()
                settle()
                print("PROBE free=\(free)   then height 1000 -> content=\(view.frame.size)",
                      "parking=\(view.stackView.trailingParkingSpace)")
            }
        }
    }
}
