import Foundation
import KeepAwakeCore

/// A clock the test drives by hand, so duration logic is verified without ever sleeping.
final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: TimeInterval

    init(now: TimeInterval = 1000) {
        self._now = now
    }

    var now: TimeInterval { lock.withLock { _now } }

    func advance(by interval: TimeInterval) {
        lock.withLock { _now += interval }
    }
}
