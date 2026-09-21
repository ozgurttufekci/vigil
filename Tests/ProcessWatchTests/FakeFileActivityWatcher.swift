import Foundation
import MonotonicTime
import ProcessWatch

/// A watcher the test drives by hand.
final class FakeFileActivityWatcher: FileActivityWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastChange: TimeInterval?
    private var _watchedPaths: [String] = []
    private var _isWatching = false

    var watchedPaths: [String] { lock.withLock { _watchedPaths } }
    var isWatching: Bool { lock.withLock { _isWatching } }

    var lastChange: TimeInterval? { lock.withLock { _lastChange } }

    func watch(paths: [String]) {
        lock.withLock {
            _watchedPaths = paths
            _isWatching = true
        }
    }

    func stop() {
        lock.withLock {
            _isWatching = false
            _lastChange = nil
        }
    }

    /// Simulates a file being written at `time`.
    func recordChange(at time: TimeInterval) {
        lock.withLock { _lastChange = time }
    }
}
