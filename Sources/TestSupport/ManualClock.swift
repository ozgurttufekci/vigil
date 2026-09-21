import Foundation
import MonotonicTime

/// A clock the test drives by hand, so duration logic is verified without ever sleeping.
public final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: TimeInterval

    public init(now: TimeInterval = 1000) {
        self._now = now
    }

    public var now: TimeInterval { lock.withLock { _now } }

    public func advance(by interval: TimeInterval) {
        lock.withLock { _now += interval }
    }
}
