import Darwin
import Foundation

/// A monotonic time source, in seconds since an arbitrary fixed point.
///
/// Durations are deliberately *not* measured against wall-clock `Date`. Wall-clock time can jump
/// backwards or forwards (NTP correction, the user changing the clock, daylight saving), which
/// would make a "keep awake for 30 minutes" hold expire early or late.
///
/// Implementations must also keep advancing while the machine is asleep. A clock that pauses during
/// sleep would let a finite hold survive an overnight suspend with time still on it, so the Mac
/// would wake and immediately refuse to sleep again.
public protocol MonotonicClock: Sendable {
    var now: TimeInterval { get }
}

/// The production clock, backed by `CLOCK_MONOTONIC_RAW`.
///
/// `ProcessInfo.systemUptime` and `CLOCK_UPTIME_RAW` are *not* suitable here: they stop while the
/// machine sleeps. Measured on a development Mac, they trailed `CLOCK_MONOTONIC_RAW` by 87 hours of
/// accumulated sleep, which would have kept stale holds alive across every suspend.
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public var now: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}
