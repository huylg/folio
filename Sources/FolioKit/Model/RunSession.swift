import Foundation

/// Identity of one code block across every surface that renders it.
///
/// A block's components are sliced verbatim out of the built document — a peek card's slice
/// keeps the original character ranges — so the range's location identifies the block in the
/// peek and in the reading pane alike. The URL is standardized here, once, so two spellings of
/// the same path can never split a block's runs across two keys.
public struct RunBlockKey: Hashable {
    public let documentURL: URL
    public let location: Int

    public init(documentURL: URL, location: Int) {
        self.documentURL = documentURL.standardizedFileURL
        self.location = location
    }
}

/// One run's shared state: the transcript so far, and the result once the command exits.
///
/// The session is the thing a run writes into — never a view. Any number of views may render
/// it at once (the reading pane's card and a peek card showing the same block), and a view
/// that dies mid-run simply stops observing; the run carries on into the session. Main-thread
/// only, which is where `ProcessRunner` already delivers.
public final class RunSession {

    public enum Event {
        /// The live transcript grew.
        case output
        /// The command exited; `entry` is set.
        case finished
        /// The session was dismissed. Late output and results are discarded from here on.
        case closed
    }

    /// A finished run, timestamped so an older console's header can say when it was.
    public struct Entry {
        public let output: ProcessRunner.Output
        public let finishedAt: Date
    }

    public let key: RunBlockKey
    public let startedAt: Date
    /// What the pty has produced so far — the live body until the command exits, and still
    /// readable after, since the result's text is derived from the same stream.
    public private(set) var liveTranscript: TerminalSnapshot = .empty
    /// The finished run — nil while the command is still running.
    public private(set) var entry: Entry?
    public private(set) var isClosed = false
    public var isRunning: Bool { entry == nil && !isClosed }

    private var observers: [UUID: (Event) -> Void] = [:]

    init(key: RunBlockKey, startedAt: Date = Date()) {
        self.key = key
        self.startedAt = startedAt
    }

    /// Registers `handler` for the session's events, synchronously on the main thread.
    /// The token unregisters it — a view must remove itself before it dies.
    public func addObserver(_ handler: @escaping (Event) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// A fresh slice of the pty stream: the full transcript so far, replace not append.
    /// Ignored once finished or closed — a dismissed console discards its late output.
    public func appendOutput(_ transcript: TerminalSnapshot) {
        guard isRunning else { return }
        liveTranscript = transcript
        notify(.output)
    }

    /// The command exited. `nil` means the host had nothing to run — the session closes and
    /// every console bound to it folds away. Ignored once closed: the reader gave up on the
    /// run before it exited, and its late result goes nowhere.
    public func finish(with output: ProcessRunner.Output?) {
        guard isRunning else { return }
        guard let output else {
            close()
            return
        }
        entry = Entry(output: output, finishedAt: Date())
        notify(.finished)
    }

    /// Dismisses the run everywhere: every bound console folds away, and the owning store
    /// drops the session. Idempotent.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        notify(.closed)
    }

    private func notify(_ event: Event) {
        // Snapshotted: a handler may unregister observers (a folding console removes itself)
        // while the walk is still going.
        for handler in Array(observers.values) { handler(event) }
    }
}

/// The document's consoles: at most one per block, and at most one run in flight — the shared
/// state behind every console.
///
/// Owned by the surface that owns the document (the reading pane), and handed to any other
/// surface rendering the same document (a peek card), which is what makes a run started in one
/// place appear in the other. A store for a document nobody has open — a cross-file peek's —
/// is simply thrown away with the peek, and a run still in flight finishes into a session
/// nobody renders.
///
/// A block keeps one console: re-running replaces it, rather than stacking a second one under
/// the code. And runs are **serial** — while any of this store's blocks is still running,
/// `begin` refuses, because two commands sharing one project root are two commands fighting
/// over the same working tree. The scope is the store, so it is the document: a peek of
/// *another* file carries its own store and its own single run.
public final class RunSessionStore {

    private var sessionsByKey: [RunBlockKey: RunSession] = [:]
    private var observers: [UUID: (RunBlockKey) -> Void] = [:]
    /// The store's own token on each session, so it can stop watching one it drops.
    private var sessionTokens: [ObjectIdentifier: UUID] = [:]

    public init() {}

    /// The block's console, or nil when it has none.
    public func session(for key: RunBlockKey) -> RunSession? {
        sessionsByKey[key]
    }

    /// The run still in flight, whichever block it belongs to — nil when the store is idle.
    public var runningSession: RunSession? {
        sessionsByKey.values.first { $0.isRunning }
    }

    /// Whether a command is running anywhere in this document. Every Run button reads it:
    /// while it is true, none of them will start a second one.
    public var isRunning: Bool { runningSession != nil }

    /// Registers `handler` for changes to any block's session — a run beginning, finishing, or
    /// closing. Fired synchronously on the main thread with the block's key.
    public func addObserver(_ handler: @escaping (RunBlockKey) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// Opens the block's session, replacing whatever it had — one block, one console.
    ///
    /// Returns nil while another run is still going: runs are serial, and the caller's Run
    /// button is already out by then, so this is the belt to that braces. Observers are
    /// notified synchronously, so a view bound to the key has its console up by the time this
    /// returns.
    @discardableResult
    public func begin(key: RunBlockKey, startedAt: Date = Date()) -> RunSession? {
        guard !isRunning else { return nil }
        let session = RunSession(key: key, startedAt: startedAt)
        watch(session)
        // Installed *before* the old one is closed: closing re-enters through `watch`'s
        // observer, and a view reacting to that must already see the session taking its place.
        let previous = sessionsByKey[key]
        sessionsByKey[key] = session
        previous?.close()
        notify(key)
        return session
    }

    /// Closes every session that no longer names a block of `documentURL`'s current build —
    /// another document's, or one whose range shifted when the file changed on disk. Sessions
    /// of unchanged blocks survive, which is what lets a console outlive a re-render.
    public func prune(keeping documentURL: URL, validLocations: Set<Int>) {
        let url = documentURL.standardizedFileURL
        for (key, session) in sessionsByKey
        where key.documentURL != url || !validLocations.contains(key.location) {
            session.close()
        }
    }

    /// The store rides along on each session so a close — from any console, or from a re-run
    /// replacing it — drops it here and tells the key's observers.
    private func watch(_ session: RunSession) {
        let token = session.addObserver { [weak self, weak session] event in
            guard let self, let session else { return }
            switch event {
            case .output:
                // The views bound to the session render the transcript themselves; the
                // store's observers care about the history changing shape.
                break
            case .finished:
                notify(session.key)
            case .closed:
                remove(session)
                notify(session.key)
            }
        }
        sessionTokens[ObjectIdentifier(session)] = token
    }

    private func remove(_ session: RunSession) {
        if let token = sessionTokens.removeValue(forKey: ObjectIdentifier(session)) {
            session.removeObserver(token)
        }
        // Only if it is still the block's session: a replaced one closes *after* its successor
        // has taken the slot, and must not carry it out with it.
        if sessionsByKey[session.key] === session {
            sessionsByKey.removeValue(forKey: session.key)
        }
    }

    private func notify(_ key: RunBlockKey) {
        for handler in Array(observers.values) { handler(key) }
    }
}

/// What a rendering surface needs to run a block and share its consoles: the identity
/// namespace for the document's blocks, the project root commands execute at, and the store
/// the sessions live in.
public struct RunContext {
    public let documentURL: URL
    public let rootURL: URL
    public let store: RunSessionStore

    public init(documentURL: URL, rootURL: URL, store: RunSessionStore) {
        self.documentURL = documentURL.standardizedFileURL
        self.rootURL = rootURL
        self.store = store
    }
}
