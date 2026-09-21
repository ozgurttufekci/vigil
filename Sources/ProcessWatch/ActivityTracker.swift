import Foundation
import MonotonicTime

/// Whether a tracked rule currently justifies keeping the Mac awake.
public enum ActivityState: Sendable, Equatable {
    /// Quiet for longer than the grace period.
    case idle
    /// Actively working.
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

/// Turns a stream of observations into a stable busy/idle decision.
///
/// The state machine is shared by both signals so hysteresis and the grace period behave
/// identically whether busyness came from CPU or from file activity.
public struct ActivityTracker: Sendable {
    public let identity: ProcessIdentity
    public let rule: ProcessRule

    private var lastCPUSample: (cpuTime: TimeInterval, at: TimeInterval)?
    private var lastSeenFileChange: TimeInterval?
    private(set) public var state: ActivityState = .idle
    /// Most recent CPU reading, for display. Always 0 for file-activity rules.
    private(set) public var cpuPercent: Double = 0

    public init(identity: ProcessIdentity, rule: ProcessRule) {
        self.identity = identity
        self.rule = rule
    }

    /// Folds in a CPU reading. Ignored unless this is a CPU rule.
    ///
    /// The first reading only establishes a baseline: CPU percent is a rate, so it needs two points.
    public mutating func record(sample: CPUSample, at now: TimeInterval) {
        guard case .cpu(let busyThreshold, let idleThreshold) = rule.signal else { return }
        defer { lastCPUSample = (sample.cpuTime, now) }

        guard let previous = lastCPUSample else { return }
        let elapsed = now - previous.at
        guard elapsed > 0 else { return }

        cpuPercent = (max(0, sample.cpuTime - previous.cpuTime) / elapsed) * 100

        // Between the two thresholds the state is left alone, so a process hovering near the line
        // cannot flap the Mac's power state.
        if cpuPercent >= busyThreshold {
            state = .busy
        } else if cpuPercent < idleThreshold {
            markQuiet(at: now)
        } else {
            advanceGrace(at: now)
        }
    }

    /// Folds in the watcher's most recent change time. Ignored unless this is a file-activity rule.
    public mutating func record(lastFileChange: TimeInterval?, at now: TimeInterval) {
        guard case .fileActivity = rule.signal else { return }

        if let lastFileChange, lastFileChange != lastSeenFileChange {
            lastSeenFileChange = lastFileChange
            state = .busy
        } else {
            markQuiet(at: now)
        }
    }

    /// Advances the grace period without a new observation.
    public mutating func tick(at now: TimeInterval) {
        advanceGrace(at: now)
    }

    private mutating func markQuiet(at now: TimeInterval) {
        switch state {
        case .busy:
            state = .cooling(since: now)
        case .cooling, .idle:
            advanceGrace(at: now)
        }
    }

    private mutating func advanceGrace(at now: TimeInterval) {
        guard case .cooling(let since) = state else { return }
        if now - since >= rule.gracePeriod {
            state = .idle
        }
    }
}
