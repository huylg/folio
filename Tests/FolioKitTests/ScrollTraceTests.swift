import AppKit
import XCTest
@testable import FolioKit

/// The scroll tracer: what it counts, what it says, and that the reading pane actually reports
/// through it. Timings are driven by an injected clock, so nothing here depends on the machine.
final class ScrollTraceTests: XCTestCase {

    private let sixty: TimeInterval = 1 / 60

    // MARK: Frame pacing

    func testEvenFramesHaveNoHitches() throws {
        let stamps = (0..<10).map { Double($0) * sixty }
        let pacing = try XCTUnwrap(FramePacing.analyze(timestamps: stamps, nominalInterval: sixty))
        XCTAssertEqual(pacing.frames, 10)
        XCTAssertEqual(pacing.hitches, 0)
        XCTAssertEqual(pacing.hitchTime, 0)
        XCTAssertEqual(pacing.refreshRate, 60)
        XCTAssertEqual(pacing.duration, 9 * sixty, accuracy: 1e-9)
        XCTAssertEqual(pacing.worstInterval, sixty, accuracy: 1e-9)
    }

    func testALateFrameIsAHitchChargedForItsOverrun() throws {
        // Three even frames, one that took three intervals to arrive, then one more even one.
        var stamps = [0, sixty, 2 * sixty]
        stamps.append(stamps[2] + 3 * sixty)
        stamps.append(stamps[3] + sixty)
        let pacing = try XCTUnwrap(FramePacing.analyze(timestamps: stamps, nominalInterval: sixty))
        XCTAssertEqual(pacing.hitches, 1)
        XCTAssertEqual(pacing.hitchTime, 2 * sixty, accuracy: 1e-9,
                       "a frame three intervals long was late by two of them")
        XCTAssertEqual(pacing.worstInterval, 3 * sixty, accuracy: 1e-9)
        XCTAssertEqual(pacing.hitchRate, pacing.hitchTime * 1000 / pacing.duration,
                       accuracy: 1e-9)
    }

    func testAFrameJustOverNominalIsNotAHitch() throws {
        // 1.4 intervals: a little slow, under the one-and-a-half threshold.
        let stamps = [0, sixty, sixty + 1.4 * sixty, sixty + 2.4 * sixty]
        let pacing = try XCTUnwrap(FramePacing.analyze(timestamps: stamps, nominalInterval: sixty))
        XCTAssertEqual(pacing.hitches, 0)
    }

    func testNothingToPaceGivesNoReport() {
        XCTAssertNil(FramePacing.analyze(timestamps: [0], nominalInterval: sixty))
        XCTAssertNil(FramePacing.analyze(timestamps: [], nominalInterval: sixty))
        XCTAssertNil(FramePacing.analyze(timestamps: [0, sixty], nominalInterval: 0))
    }

    // MARK: Phases

    /// A tracer on a clock the test advances by hand, collecting what it prints.
    private func tracer(enabled: Bool = true)
        -> (trace: ScrollTrace, advance: (TimeInterval) -> Void, lines: () -> [String]) {
        var clock: TimeInterval = 0
        var lines: [String] = []
        let trace = ScrollTrace(enabled: enabled)
        trace.now = { clock }
        trace.sink = { lines.append($0) }
        return (trace, { clock += $0 }, { lines })
    }

    func testDisabledTracerRecordsNothing() {
        let (trace, advance, lines) = tracer(enabled: false)
        trace.measure(.populateVisible) { advance(0.020) }
        trace.viewportEvent { advance(0.020) }
        trace.gestureBegan(in: nil)
        XCTAssertTrue(trace.phases.isEmpty)
        XCTAssertNil(trace.finishGesture())
        XCTAssertTrue(lines().isEmpty)
    }

    func testMeasureAccumulatesCountTotalAndWorst() {
        let (trace, advance, _) = tracer()
        trace.measure(.populateVisible) { advance(0.002) }
        trace.measure(.populateVisible) { advance(0.005) }
        let stats = trace.phases[.populateVisible]
        XCTAssertEqual(stats?.count, 2)
        XCTAssertEqual(stats?.total ?? 0, 0.007, accuracy: 1e-9)
        XCTAssertEqual(stats?.worst ?? 0, 0.005, accuracy: 1e-9)
    }

    func testMeasureHandsBackTheBodysValue() {
        let (trace, _, _) = tracer()
        XCTAssertEqual(trace.measure(.headingProbe) { 42 }, 42)
        XCTAssertEqual(ScrollTrace(enabled: false).measure(.headingProbe) { "off" }, "off")
    }

    func testASlowViewportEventPrintsItsBreakdown() {
        let (trace, advance, lines) = tracer()
        trace.viewportEvent {
            trace.measure(.populateVisible) {
                trace.measure(.installView) { advance(0.004) }
                trace.measure(.installView) { advance(0.004) }
                advance(0.001)
            }
            trace.measure(.reportViewport) { advance(0.003) }
        }
        XCTAssertEqual(lines().count, 1)
        let line = lines()[0]
        XCTAssertTrue(line.contains("slow viewport event: 12.0ms"), line)
        XCTAssertTrue(line.contains("populateVisible 9.0×1"), line)
        XCTAssertTrue(line.contains("installView 8.0×2"), line)
        XCTAssertTrue(line.contains("reportViewport 3.0×1"), line)
    }

    func testAFastViewportEventIsSilent() {
        let (trace, advance, lines) = tracer()
        trace.viewportEvent { trace.measure(.populateVisible) { advance(0.001) } }
        XCTAssertTrue(lines().isEmpty)
        XCTAssertEqual(trace.phases[.viewportChanged]?.count, 1)
    }

    // MARK: Gestures

    func testAGestureSummaryRanksItsPhasesByCost() throws {
        let (trace, advance, lines) = tracer()
        // Work before the gesture is not the gesture's.
        trace.measure(.drawText) { advance(0.050) }

        trace.gestureBegan(in: nil)
        trace.viewportEvent { trace.measure(.populateVisible) { advance(0.002) } }
        trace.viewportEvent { trace.measure(.reportViewport) { advance(0.001) } }
        trace.measure(.drawText) { advance(0.004) }
        trace.measure(.drawText) { advance(0.004) }
        advance(0.100)
        let summary = try XCTUnwrap(trace.finishGesture())

        XCTAssertEqual(summary.events, 2)
        XCTAssertEqual(summary.maxEventsPerFrame, 2, "no display link: the whole gesture is one frame")
        XCTAssertNil(summary.pacing, "no display link, no frames")
        XCTAssertEqual(summary.phases[.drawText]?.count, 2,
                       "the draw before the gesture began does not count")
        XCTAssertEqual(summary.phases[.drawText]?.total ?? 0, 0.008, accuracy: 1e-9)

        let printed = lines()
        XCTAssertEqual(printed, summary.lines)
        XCTAssertEqual(printed.count, 1 + summary.phases.count)
        XCTAssertTrue(printed[0].contains("frames n/a"), printed[0])
        XCTAssertTrue(printed[0].contains("2 viewport events (≤2/frame)"), printed[0])
        // Costliest first: the draws (8ms), then the two events' wrapper (3ms), then populate.
        XCTAssertTrue(printed[1].contains("drawText"), printed[1])
        XCTAssertTrue(printed[2].contains("viewportChanged"), printed[2])
        XCTAssertTrue(printed[3].contains("populateVisible"), printed[3])
    }

    func testTheSummaryWaitsForTheCoastAfterTheHandLifts() {
        let (trace, advance, lines) = tracer()
        trace.gestureBegan(in: nil)
        trace.viewportEvent { advance(0.001) }
        trace.gestureEnded()
        // Momentum is still delivering events; nothing is printed until it settles.
        trace.viewportEvent { advance(0.001) }
        XCTAssertTrue(lines().isEmpty)
        XCTAssertEqual(trace.finishGesture()?.events, 2)
        XCTAssertEqual(lines().count, 2)
        XCTAssertNil(trace.finishGesture(), "a finished gesture cannot finish twice")
    }

    func testANewGestureClosesTheOneBeforeIt() {
        let (trace, advance, lines) = tracer()
        trace.gestureBegan(in: nil)
        trace.viewportEvent { advance(0.001) }
        trace.gestureBegan(in: nil)
        XCTAssertEqual(lines().count, 2, "the first gesture's summary was printed")
        XCTAssertTrue(trace.phases.isEmpty, "and the second starts clean")
    }

    // MARK: The reading pane

    private let metrics = DocumentMetrics(
        ramp: TypeRamp(family: .serif, textSize: 13),
        lineWidth: .comfortable, density: .airy
    )

    private func sampleDocument() throws -> MarkdownDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
        return try MarkdownDocument(url: url)
    }

    private func settle(_ view: NSView, turns: Int = 12) {
        view.layoutSubtreeIfNeeded()
        for _ in 0..<turns {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// The window is returned so the caller keeps it alive; it is never closed — a
    /// programmatically made window releases itself on close, and ARC releasing it again is
    /// a crash.
    private func makeReadingPane() throws -> (NativeDocumentView, NSWindow) {
        let view = NativeDocumentView(metrics: metrics)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = TestWindow(contentRect: view.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.render(document: try sampleDocument(), metrics: metrics)
        settle(view)
        return (view, window)
    }

    /// Swaps the process-wide tracer for the test's, and back afterwards.
    private func install(_ trace: ScrollTrace) {
        let previous = ScrollTrace.shared
        ScrollTrace.shared = trace
        addTeardownBlock { ScrollTrace.shared = previous }
    }

    func testScrollingTheReadingPaneTracesEveryPhaseOfTheScroll() throws {
        let (trace, _, _) = tracer()
        trace.now = { CACurrentMediaTime() }
        install(trace)
        let (view, window) = try makeReadingPane()
        withExtendedLifetime(window) {}

        trace.gestureBegan(in: nil)
        let clip = view.scrollView.contentView
        for y in stride(from: 300, through: 2400, by: 300) {
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(y)))
            view.scrollView.reflectScrolledClipView(clip)
        }
        // A window ordered back off screen never displays on its own; the cache walk is what
        // the snapshot renderer uses to make every component draw.
        let stack = view.stackView
        let rep = try XCTUnwrap(stack.bitmapImageRepForCachingDisplay(in: stack.visibleRect))
        stack.cacheDisplay(in: stack.visibleRect, to: rep)
        let summary = try XCTUnwrap(trace.finishGesture())

        XCTAssertGreaterThanOrEqual(summary.events, 8, "one viewport event per scroll")
        for phase in [ScrollTrace.Phase.viewportChanged, .populateVisible, .captureAnchor,
                      .reportViewport, .visibleSections, .headingProbe] {
            XCTAssertGreaterThan(summary.phases[phase]?.count ?? 0, 0,
                                 "\(phase.rawValue) was not traced")
        }
        XCTAssertGreaterThan(summary.phases[.installView]?.count ?? 0, 0,
                             "scrolling two screens down vends new views")
        XCTAssertGreaterThan(summary.phases[.configureText]?.count ?? 0, 0,
                             "and configures prose for them")
        XCTAssertGreaterThan(summary.phases[.drawText]?.count ?? 0, 0,
                             "the display pass draws prose")
        XCTAssertGreaterThan(summary.phases[.layoutText]?.count ?? 0, 0,
                             "and lays it out — where a layer-backed window paints it")
        XCTAssertNil(summary.phases[.measure],
                     "a scroll must never re-measure the document")
    }

    func testADisabledTracerLeavesTheReadingPaneSilent() throws {
        let (trace, _, lines) = tracer(enabled: false)
        install(trace)
        let (view, window) = try makeReadingPane()
        withExtendedLifetime(window) {}
        let clip = view.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 600))
        view.scrollView.reflectScrolledClipView(clip)
        XCTAssertTrue(trace.phases.isEmpty)
        XCTAssertTrue(lines().isEmpty)
    }
}
