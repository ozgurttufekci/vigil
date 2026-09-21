import Foundation

/// A monotonic time source, in seconds since an arbitrary fixed reference.
///
/// Durations are deliberately *not* measured against wall-clock `Date`. Wall-clock time can jump
/// backwards or forwards (NTP correction, the user changing the clock, daylight saving), which
/// would make a "keep awake for 30 minutes" hold expire early or late. A monotonic source cannot
/// jump.
public protocol MonotonicClock: Sendable {
    var uptime: TimeInterval { get }
}

/// The production clock.
///
/// `systemUptime` does not advance while the machine is asleep. That is the desired behaviour here:
/// if the Mac slept, any outstanding keep-awake hold is already moot.
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public var uptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
