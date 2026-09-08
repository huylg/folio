import AppKit
import os

/// Opt-in tracing of what a scroll costs, for chasing a scroll that is not smooth.
///
/// Off unless `FOLIO_SCROLL_TRACE` is set in the environment, and a single flag check when off.
/// On, it does three things:
///
/// - Wraps every phase of a viewport change — the view vending pass, the reading-anchor
///   capture, the outline report, each text relayout and card draw — in an `os_signpost`
///   interval, so Instruments' *os_signpost* track shows exactly what ran inside each frame.
///   The display pass that follows the handler is traced too — text layout, and the draws —
///   because under a layer-backed window that is where the text is painted, and a frame can
///   run late there with the handler itself well under budget.
/// - Watches the display link for the length of a live scroll and counts the frames that came
///   late: a *hitch* is a frame that took more than one and a half refresh intervals, which is
///   the thing a reader feels as a stutter. Needs macOS 14 for `NSView.displayLink`; below that
///   the frame column reads "n/a" and the phase timings still apply.
/// - Prints one summary per gesture, and one line for any single viewport event slow enough to
///   have cost a frame by itself, to stderr and to the unified log under
///   `io.huylg.folio/scroll`:
///
///   ```
///   log stream --predicate 'subsystem == "io.huylg.folio" AND category == "scroll"'
///   ```
///
/// Timing rather than counting, because the counters this project already keeps — measures,
/// configures — say *whether* a thing happened and this has to say whether it was the thing
/// that cost the frame.
public final class ScrollTrace {

    /// The stretches of work a scroll can spend a frame on.
    public enum Phase: String, CaseIterable {
        /// The whole handler for one `boundsDidChange` of the clip view.
        case viewportChanged
        /// Deciding which placements are near the viewport and vending views for them.
        case populateVisible
        /// Building or reclaiming one component's view.
        case installView
        /// A prose view taking new text — a full TextKit relayout.
        case configureText
        /// Re-measuring and re-paginating the document. Should never run mid-scroll.
        case measure
        /// Working out where the reader is, for the position restore.
        case captureAnchor
        /// The outline report as a whole.
        case reportViewport
        /// Which sections are on screen.
        case visibleSections
        /// Which heading the reading line has reached.
        case headingProbe
        /// The outline reacting to the report.
        case outlineUpdate
        /// A prose component laying out. Under a layer-backed window — the reading pane is one
        /// — TextKit 2 renders text here rather than in `draw`, so this is where the text is
        /// actually painted, and every prose view on screen runs it on every scroll.
        case layoutText
        /// A prose component drawing. Next to nothing when layer-backed; see `layoutText`.
        case drawText
        /// A card-shaped block drawing.
        case drawCard
        /// The page itself drawing — the dividers between spreads.
        case drawPage

        /// `os_signpost` takes a `StaticString`, so the names are spelled out rather than
        /// derived from `rawValue`.
        var signpostName: StaticString {
            switch self {
            case .viewportChanged: return "viewportChanged"
            case .populateVisible: return "populateVisible"
            case .installView: return "installView"
            case .configureText: return "configureText"
            case .measure: return "measure"
            case .captureAnchor: return "captureAnchor"
            case .reportViewport: return "reportViewport"
            case .visibleSections: return "visibleSections"
            case .headingProbe: return "headingProbe"
            case .outlineUpdate: return "outlineUpdate"
            case .layoutText: return "layoutText"
            case .drawText: return "drawText"
            case .drawCard: return "drawCard"
            case .drawPage: return "drawPage"
            }
        }
    }

    /// How often a phase ran and what it cost, over one gesture or one event.
    public struct PhaseStats: Equatable {
        public var count = 0
        public var total: TimeInterval = 0
        public var worst: TimeInterval = 0

        mutating func add(_ elapsed: TimeInterval) {
            count += 1
            total += elapsed
            worst = max(worst, elapsed)
        }

        /// This minus an earlier snapshot: what happened in between.
        func since(_ earlier: PhaseStats?) -> PhaseStats {
            guard let earlier else { return self }
            return PhaseStats(count: count - earlier.count, total: total - earlier.total,
                              worst: worst)
        }
    }

    /// The process-wide tracer. A `var` so a test can stand in its own.
    public static var shared = ScrollTrace(
        enabled: ProcessInfo.processInfo.environment["FOLIO_SCROLL_TRACE"] != nil
    )

    public let isEnabled: Bool

    /// Where the lines go. The default writes to stderr and the unified log; tests collect.
    var sink: (String) -> Void
    /// The clock, injectable so a test can measure a phase deterministically.
    var now: () -> TimeInterval = { CACurrentMediaTime() }

    /// A single viewport event slower than this gets a line of its own, with its breakdown. Half
    /// a 60Hz frame: an event that long has left no room for the draw that follows it.
    static var slowEventThreshold: TimeInterval = 0.008
    /// How long after the last viewport event a gesture is taken to be over. Momentum carries on
    /// past `didEndLiveScroll`, and a summary printed at the lift-off would miss the coast.
    static var settleDelay: TimeInterval = 0.25

    private let signposter = OSSignposter(subsystem: "io.huylg.folio", category: "scroll")
    private let log = Logger(subsystem: "io.huylg.folio", category: "scroll")

    public init(enabled: Bool) {
        isEnabled = enabled
        sink = { _ in }
        sink = { [log] line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
            log.notice("\(line, privacy: .public)")
        }
    }

    // MARK: Phases

    /// The phases seen since the gesture began — or since the tracer was made, outside one.
    private(set) var phases: [Phase: PhaseStats] = [:]

    /// Times `body` as `phase`. Free when tracing is off.
    @discardableResult
    func measure<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let state = signposter.beginInterval(phase.signpostName, id: signposter.makeSignpostID())
        let start = now()
        defer {
            record(phase, elapsed: now() - start)
            signposter.endInterval(phase.signpostName, state)
        }
        return try body()
    }

    private func record(_ phase: Phase, elapsed: TimeInterval) {
        phases[phase, default: PhaseStats()].add(elapsed)
    }

    // MARK: Viewport events

    private var eventStart: TimeInterval?
    private var eventSnapshot: [Phase: PhaseStats] = [:]
    private var events = 0
    private var eventsThisFrame = 0
    private var maxEventsPerFrame = 0

    /// Brackets one viewport change. The phases inside it are measured on their own; this adds
    /// the whole, and the slow-event line when the whole was too much.
    func viewportEvent<T>(_ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        eventStart = now()
        eventSnapshot = phases
        events += 1
        eventsThisFrame += 1
        defer { endEvent() }
        return try measure(.viewportChanged, body)
    }

    private func endEvent() {
        guard let start = eventStart else { return }
        eventStart = nil
        let elapsed = now() - start
        // A gesture already signalled its end is still coasting; the summary waits for it.
        if finishWork != nil { scheduleFinish() }
        guard elapsed > Self.slowEventThreshold else { return }
        var breakdown: [String] = []
        for phase in Phase.allCases where phase != .viewportChanged {
            let delta = phases[phase]?.since(eventSnapshot[phase]) ?? PhaseStats()
            guard delta.count > 0 else { continue }
            breakdown.append("\(phase.rawValue) \(Self.ms(delta.total))×\(delta.count)")
        }
        sink("[scroll] slow viewport event: \(Self.ms(elapsed))ms — "
             + (breakdown.isEmpty ? "no traced phase" : breakdown.joined(separator: ", ")))
    }

    // MARK: Gestures

    private var gestureStart: TimeInterval?
    private var frameTimestamps: [TimeInterval] = []
    private var nominalFrameInterval: TimeInterval = 0
    /// A `FrameWatcher`, typed loosely because the class only exists on macOS 14.
    private var frameWatcher: AnyObject?
    private var finishWork: DispatchWorkItem?

    /// The reader put a hand on the scroll. Starts a fresh gesture: counters cleared, the
    /// display link watched from `view`'s screen — or no frames at all, for a test with no
    /// screen to watch.
    func gestureBegan(in view: NSView?) {
        guard isEnabled else { return }
        finishGesture()
        gestureStart = now()
        phases = [:]
        events = 0
        eventsThisFrame = 0
        maxEventsPerFrame = 0
        frameTimestamps = []
        nominalFrameInterval = 0
        if let view { startDisplayLink(in: view) }
    }

    /// The live scroll ended. The summary follows once the viewport has been still for
    /// `settleDelay`, so a flick's coast is counted with the gesture that started it.
    func gestureEnded() {
        guard isEnabled, gestureStart != nil else { return }
        scheduleFinish()
    }

    private func scheduleFinish() {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishGesture() }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Closes the gesture in progress and emits its summary. Nothing when there is none.
    @discardableResult
    func finishGesture() -> GestureSummary? {
        finishWork?.cancel()
        finishWork = nil
        stopDisplayLink()
        guard let start = gestureStart else { return nil }
        gestureStart = nil
        maxEventsPerFrame = max(maxEventsPerFrame, eventsThisFrame)
        let summary = GestureSummary(
            duration: now() - start,
            events: events,
            maxEventsPerFrame: maxEventsPerFrame,
            pacing: FramePacing.analyze(timestamps: frameTimestamps,
                                        nominalInterval: nominalFrameInterval),
            phases: phases
        )
        for line in summary.lines { sink(line) }
        return summary
    }

    private func startDisplayLink(in view: NSView) {
        stopDisplayLink()
        guard #available(macOS 14.0, *) else { return }
        nominalFrameInterval = 1 / TimeInterval(max(1, view.window?.screen?.maximumFramesPerSecond
                                                           ?? NSScreen.main?.maximumFramesPerSecond
                                                           ?? 60))
        frameWatcher = FrameWatcher(view: view) { [weak self] timestamp, interval in
            self?.frameTick(at: timestamp, interval: interval)
        }
    }

    private func stopDisplayLink() {
        if #available(macOS 14.0, *) { (frameWatcher as? FrameWatcher)?.stop() }
        frameWatcher = nil
    }

    private func frameTick(at timestamp: TimeInterval, interval: TimeInterval) {
        frameTimestamps.append(timestamp)
        // The link's own idea of the refresh interval beats the screen's ceiling: a
        // variable-rate display may be running below its maximum.
        if interval > 0 { nominalFrameInterval = interval }
        maxEventsPerFrame = max(maxEventsPerFrame, eventsThisFrame)
        eventsThisFrame = 0
    }

    // MARK: Summary

    /// One gesture, summed up.
    public struct GestureSummary: Equatable {
        public let duration: TimeInterval
        public let events: Int
        public let maxEventsPerFrame: Int
        public let pacing: FramePacing?
        public let phases: [Phase: PhaseStats]

        /// The lines the tracer prints for this gesture: a headline, then one row per phase
        /// that ran, costliest first.
        public var lines: [String] {
            var headline = "[scroll] gesture \(ScrollTrace.seconds(duration))s · "
            if let pacing {
                headline += "\(pacing.frames) frames @\(pacing.refreshRate)Hz · "
                headline += "\(pacing.hitches) hitch\(pacing.hitches == 1 ? "" : "es")"
                if pacing.hitches > 0 {
                    headline += " (worst \(ScrollTrace.ms(pacing.worstInterval))ms, "
                        + "\(Int(pacing.hitchRate.rounded())) ms/s)"
                }
                headline += " · "
            } else {
                headline += "frames n/a · "
            }
            headline += "\(events) viewport event\(events == 1 ? "" : "s")"
            if events > 0 { headline += " (≤\(maxEventsPerFrame)/frame)" }
            var lines = [headline]

            let width = Phase.allCases.map { $0.rawValue.count }.max() ?? 0
            let ranked = phases.filter { $0.value.count > 0 }
                .sorted { $0.value.total > $1.value.total }
            for (phase, stats) in ranked {
                let name = phase.rawValue.padding(toLength: width, withPad: " ",
                                                  startingAt: 0)
                lines.append("[scroll]   \(name) \(String(format: "%5d", stats.count))×  "
                             + "total \(ScrollTrace.ms(stats.total).leftPadded(to: 7))ms  "
                             + "avg \(ScrollTrace.ms(stats.total / Double(stats.count)).leftPadded(to: 6))ms  "
                             + "worst \(ScrollTrace.ms(stats.worst).leftPadded(to: 6))ms")
            }
            return lines
        }
    }

    static func ms(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval * 1000)
    }

    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f", interval)
    }
}

/// How evenly frames arrived over a gesture.
///
/// Derived from display-link timestamps alone: a callback that ran late did so because the main
/// thread was busy, whatever it was busy with, so the gaps between callbacks are the honest
/// measure of the stutter the reader saw — independent of which phase this project happened to
/// instrument.
public struct FramePacing: Equatable {
    /// How many display-link callbacks arrived.
    public let frames: Int
    /// From the first callback to the last.
    public let duration: TimeInterval
    /// The display's refresh interval.
    public let nominalInterval: TimeInterval
    /// Frames that took more than `hitchFactor` refresh intervals to arrive.
    public let hitches: Int
    /// The time those frames were late by, in total — Apple's "hitch time".
    public let hitchTime: TimeInterval
    /// The longest gap between two callbacks.
    public let worstInterval: TimeInterval

    /// A frame this many refresh intervals long counts as a hitch. One and a half, rather than
    /// two, so a frame that overran by a little at 60Hz — the ones that read as a faint judder
    /// rather than a skip — still counts.
    public static let hitchFactor = 1.5

    /// Hitch time per second of gesture, in milliseconds — the scale Apple's performance
    /// guidance uses: under 5 is smooth, 5–10 is noticeable, over 10 is bad.
    public var hitchRate: Double {
        duration > 0 ? hitchTime * 1000 / duration : 0
    }

    /// The nominal refresh rate, rounded to whole hertz.
    public var refreshRate: Int {
        nominalInterval > 0 ? Int((1 / nominalInterval).rounded()) : 0
    }

    /// `nil` with fewer than two timestamps or no refresh interval: nothing to pace.
    public static func analyze(timestamps: [TimeInterval], nominalInterval: TimeInterval)
        -> FramePacing? {
        guard timestamps.count >= 2, nominalInterval > 0 else { return nil }
        var hitches = 0
        var hitchTime: TimeInterval = 0
        var worst: TimeInterval = 0
        for (earlier, later) in zip(timestamps, timestamps.dropFirst()) {
            let interval = later - earlier
            worst = max(worst, interval)
            guard interval > nominalInterval * hitchFactor else { continue }
            hitches += 1
            hitchTime += interval - nominalInterval
        }
        return FramePacing(
            frames: timestamps.count,
            duration: timestamps[timestamps.count - 1] - timestamps[0],
            nominalInterval: nominalInterval,
            hitches: hitches,
            hitchTime: hitchTime,
            worstInterval: worst
        )
    }
}

/// The display link for one gesture, on the screen `view` is shown on.
///
/// Its own class because `CADisplayLink` arrived on macOS 14 and the app runs on 13: the tracer
/// holds this as `AnyObject` and only names the type under an availability check.
@available(macOS 14.0, *)
private final class FrameWatcher {
    private var link: CADisplayLink?
    private let onFrame: (_ timestamp: TimeInterval, _ interval: TimeInterval) -> Void

    init(view: NSView, onFrame: @escaping (TimeInterval, TimeInterval) -> Void) {
        self.onFrame = onFrame
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        // `.common`, because a live scroll runs the event-tracking mode and a link on the
        // default mode alone would fall silent for exactly the frames being measured.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The link retains its target, so this is what lets the watcher go.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        onFrame(link.timestamp, link.duration)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
