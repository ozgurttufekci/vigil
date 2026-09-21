import Foundation
import KeepAwakeCore

/// A clock the test drives by hand, so duration logic is verified without ever sleeping.
final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _uptime: TimeInterval

    init(uptime: TimeInterval = 1000) {
        self._uptime = uptime
    }

    var uptime: TimeInterval { lock.withLock { _uptime } }

    func advance(by interval: TimeInterval) {
        lock.withLock { _uptime += interval }
    }
}
