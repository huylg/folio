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
    public private(set) var liveTranscript = ""
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
    public func appendOutput(_ transcript: String) {
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

/// The per-block run history, newest first — the shared state behind every console.
///
/// Owned by the surface that owns the document (the reading pane), and handed to any other
/// surface rendering the same document (a peek card), which is what makes a run started in one
/// place appear in the other. A store for a document nobody has open — a cross-file peek's —
/// is simply thrown away with the peek, and a run still in flight finishes into a session
/// nobody renders.
public final class RunSessionStore {

    /// Older sessions beyond this fall off the bottom of a block's history.
    public static let maxRunHistory = 10

    private var sessionsByKey: [RunBlockKey: [RunSession]] = [:]
    private var observers: [UUID: (RunBlockKey) -> Void] = [:]
    /// The store's own token on each session, so it can stop watching one it drops.
    private var sessionTokens: [ObjectIdentifier: UUID] = [:]

    public init() {}

    /// The sessions for one block, newest first.
    public func sessions(for key: RunBlockKey) -> [RunSession] {
        sessionsByKey[key] ?? []
    }

    /// Registers `handler` for changes to any block's session list — a run beginning,
    /// finishing, or closing. Fired synchronously on the main thread with the block's key.
    public func addObserver(_ handler: @escaping (RunBlockKey) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// Opens a new session at the top of the block's history, closing any that the cap pushes
    /// off the bottom. Observers are notified synchronously, so a view bound to the key has
    /// its console up by the time this returns.
    @discardableResult
    public func begin(key: RunBlockKey, startedAt: Date = Date()) -> RunSession {
        let session = RunSession(key: key, startedAt: startedAt)
        watch(session)
        var list = sessionsByKey[key] ?? []
        list.insert(session, at: 0)
        sessionsByKey[key] = list
        if list.count > Self.maxRunHistory {
            // `close()` re-enters through `watch`'s observer, which removes each one from the
            // stored list; the walk is over this local snapshot.
            for dropped in list[Self.maxRunHistory...] { dropped.close() }
        }
        notify(key)
        return session
    }

    /// Closes every session that no longer names a block of `documentURL`'s current build —
    /// another document's, or one whose range shifted when the file changed on disk. Sessions
    /// of unchanged blocks survive, which is what lets a console outlive a re-render.
    public func prune(keeping documentURL: URL, validLocations: Set<Int>) {
        let url = documentURL.standardizedFileURL
        for (key, list) in sessionsByKey
        where key.documentURL != url || !validLocations.contains(key.location) {
            for session in list { session.close() }
        }
    }

    /// The store rides along on each session so a close — from any console, or from the cap —
    /// drops it here and tells the key's observers.
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
        sessionsByKey[session.key]?.removeAll { $0 === session }
        if sessionsByKey[session.key]?.isEmpty == true {
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
