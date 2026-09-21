import Foundation
import MonotonicTime

/// Reports whether files under a set of paths have changed recently.
public protocol FileActivityWatching: AnyObject, Sendable {
    /// Begins watching. Replaces any previous set of paths.
    func watch(paths: [String])
    /// Stops watching and forgets recorded activity.
    func stop()
    /// Monotonic time of the most recent change, or `nil` if nothing has changed since watching
    /// began.
    var lastChange: TimeInterval? { get }
}

/// Watches paths with FSEvents.
///
/// ## Why FSEvents rather than polling
///
/// The obvious approach — periodically walking the directory and comparing modification times —
/// would mean stat-ing a whole tree every few seconds. FSEvents is a kernel-backed notification
/// stream, so an idle watcher costs nothing.
///
/// ## Privacy
///
/// Which files changed is deliberately discarded. Only the time of the most recent change is kept,
/// so no file name or path from a watched directory is ever stored, logged, or displayed.
public final class DarwinFileActivityWatcher: FileActivityWatching, @unchecked Sendable {
    private let clock: MonotonicClock
    private let queue = DispatchQueue(label: "dev.vigil.file-activity")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var _lastChange: TimeInterval?
    private var watchedPaths: [String] = []

    public init(clock: MonotonicClock) {
        self.clock = clock
    }

    deinit {
        tearDown()
    }

    public var lastChange: TimeInterval? {
        lock.withLock { _lastChange }
    }

    public func watch(paths: [String]) {
        let expanded =
            paths
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted()

        lock.lock()
        let unchanged = expanded == watchedPaths && stream != nil
        lock.unlock()
        guard !unchanged else { return }

        tearDown()
        guard !expanded.isEmpty else { return }

        lock.withLock { watchedPaths = expanded }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DarwinFileActivityWatcher>.fromOpaque(info)
                .takeUnretainedValue()
            watcher.recordChange()
        }

        // `noDefer` reports the first event in a burst immediately rather than at the end of the
        // latency window, so a session that has just started writing is noticed promptly.
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                expanded as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents
                )
            )
        else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        lock.withLock { self.stream = stream }
    }

    public func stop() {
        tearDown()
        lock.withLock {
            _lastChange = nil
            watchedPaths = []
        }
    }

    private func recordChange() {
        let now = clock.now
        lock.withLock { _lastChange = now }
    }

    private func tearDown() {
        let existing: FSEventStreamRef? = lock.withLock {
            let s = stream
            stream = nil
            return s
        }
        guard let existing else { return }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
    }
}
