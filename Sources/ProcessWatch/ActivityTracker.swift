import Foundation
import MonotonicTime

/// Whether a tracked process currently justifies keeping the Mac awake.
public enum ActivityState: Sendable, Equatable {
    /// Below the idle threshold for longer than the grace period.
    case idle
    /// At or above the busy threshold.
    case busy
    /// Recently quiet, still inside the grace period. Still holds the Mac awake.
    case cooling(since: TimeInterval)

    public var keepsAwake: Bool {
        switch self {
        case .idle: false
        case .busy, .cooling: true
        }
    }
}

/// Tracks one process's CPU usage and decides whether it is working.
///
/// ## Why CPU and not mere presence
///
/// A Copilot helper spawned by VS Code lives for the whole editor session. Measured on a
/// development Mac it stayed resident for 13 minutes of idling, and sat at 117–168% CPU only while
/// actually working. Holding the Mac awake merely because the process exists would pin it awake for
/// as long as the editor is open — worse than the problem this app solves.
public struct ActivityTracker: Sendable {
    public let identity: ProcessIdentity
    public let rule: ProcessRule

    private var lastSample: (cpuTime: TimeInterval, at: TimeInterval)?
    private(set) public var state: ActivityState = .idle
    private(set) public var cpuPercent: Double = 0

    public init(identity: ProcessIdentity, rule: ProcessRule) {
        self.identity = identity
        self.rule = rule
    }

    /// Folds in a new reading and advances the state machine.
    ///
    /// The first reading only establishes a baseline: CPU percent is a rate, so it needs two points.
    public mutating func record(sample: CPUSample, at now: TimeInterval) {
        defer { lastSample = (sample.cpuTime, now) }

        guard let previous = lastSample else { return }
        let elapsed = now - previous.at
        guard elapsed > 0 else { return }

        let consumed = max(0, sample.cpuTime - previous.cpuTime)
        cpuPercent = (consumed / elapsed) * 100
        advance(at: now)
    }

    /// Advances the grace period without a new reading, so a cooling process still expires.
    public mutating func tick(at now: TimeInterval) {
        advance(at: now)
    }

    private mutating func advance(at now: TimeInterval) {
        switch state {
        case .idle:
            if cpuPercent >= rule.busyThreshold {
                state = .busy
            }
        case .busy:
            if cpuPercent < rule.idleThreshold {
                state = .cooling(since: now)
            }
        case .cooling(let since):
            if cpuPercent >= rule.busyThreshold {
                state = .busy
            } else if now - since >= rule.gracePeriod {
                state = .idle
            }
        }
    }
}
