import Foundation
import MonotonicTime

/// A process that is currently keeping the Mac awake.
///
/// Deliberately carries no command-line text. Arguments routinely contain API keys and access
/// tokens, so they are matched inside the sampler and discarded there.
public struct ActiveDetection: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    /// The rule that matched, for display.
    public let ruleID: String
    public let ruleName: String
    /// The executable's file name, safe to display.
    public let processName: String
    public let cpuPercent: Double
    public let isCoolingDown: Bool
}

/// Watches for processes matching the enabled rules and reports which are working.
///
/// Sampling is split in two tiers to stay cheap: a full process sweep runs rarely, while CPU
/// sampling of already-matched processes runs often and costs only a syscall per tracked process.
/// Shelling out to `ps` on a timer would waste exactly the energy this app exists to save.
public final class AutoDetectEngine {
    public struct Configuration: Sendable {
        /// How often to sweep every process looking for new matches.
        public let discoveryInterval: TimeInterval
        /// How often to re-sample CPU for already-tracked processes.
        public let samplingInterval: TimeInterval

        public init(discoveryInterval: TimeInterval = 30, samplingInterval: TimeInterval = 5) {
            self.discoveryInterval = max(discoveryInterval, 1)
            self.samplingInterval = max(samplingInterval, 1)
        }
    }

    private let sampler: ProcessSampling
    private let clock: MonotonicClock
    private let configuration: Configuration
    private let makeWatcher: @Sendable () -> FileActivityWatching
    private var trackers: [ProcessIdentity: ActivityTracker] = [:]
    /// One watcher per file-activity rule, created lazily when the rule first matches a process.
    private var watchers: [String: FileActivityWatching] = [:]
    private var lastDiscovery: TimeInterval?

    public var rules: [ProcessRule]

    public init(
        sampler: ProcessSampling,
        clock: MonotonicClock,
        rules: [ProcessRule] = ProcessRule.presets,
        configuration: Configuration = .init(),
        makeWatcher: (@Sendable () -> FileActivityWatching)? = nil
    ) {
        self.sampler = sampler
        self.clock = clock
        self.rules = rules
        self.configuration = configuration
        self.makeWatcher = makeWatcher ?? { DarwinFileActivityWatcher(clock: clock) }
    }

    /// Processes currently justifying a hold.
    public var activeDetections: [ActiveDetection] {
        trackers.values
            .filter { $0.state.keepsAwake }
            .map { tracker in
                let isCooling: Bool
                if case .cooling = tracker.state { isCooling = true } else { isCooling = false }
                return ActiveDetection(
                    pid: tracker.identity.pid,
                    ruleID: tracker.rule.id,
                    ruleName: tracker.rule.displayName,
                    processName: tracker.identity.name,
                    cpuPercent: tracker.cpuPercent,
                    isCoolingDown: isCooling
                )
            }
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Whether anything matched is currently working.
    public var shouldKeepAwake: Bool {
        trackers.values.contains { $0.state.keepsAwake }
    }

    /// Runs one cycle. Call on the sampling interval; discovery self-throttles.
    public func refresh() {
        let now = clock.now

        if lastDiscovery.map({ now - $0 >= configuration.discoveryInterval }) ?? true {
            discover(at: now)
            lastDiscovery = now
        }

        sampleTracked(at: now)
        // Sync after sampling, so a watcher stops in the same cycle the process it belongs to is
        // found to have exited rather than lingering until the next discovery sweep.
        syncWatchers()
    }

    /// Forgets all tracked processes, e.g. when auto-detect is turned off.
    public func reset() {
        trackers.removeAll()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        lastDiscovery = nil
    }

    private func discover(at now: TimeInterval) {
        let enabled = rules.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            trackers.removeAll()
            return
        }

        // One sweep for all rules: reading every process's arguments is the expensive part, so it
        // must not be repeated per rule. Attribution happens inside the closure because the command
        // line is deliberately unavailable afterwards.
        let matches = sampler.findProcesses { commandLine in
            enabled.first { $0.matches(commandLine: commandLine) }?.id
        }

        let rulesByID = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })

        for match in matches {
            guard let rule = rulesByID[match.ruleID] else { continue }
            if let existing = trackers[match.identity], existing.rule.id == rule.id { continue }
            trackers[match.identity] = ActivityTracker(identity: match.identity, rule: rule)
        }

        // Drop trackers whose rule was disabled or removed while running.
        for (identity, tracker) in trackers where rulesByID[tracker.rule.id] == nil {
            trackers[identity] = nil
        }
    }

    /// Starts watchers for file-activity rules that have a live process, and stops the rest.
    ///
    /// Watching is tied to the process existing so that a stale log file being touched by something
    /// else cannot pin the Mac awake while the tool is not running.
    private func syncWatchers() {
        let live = Dictionary(
            trackers.values.map { ($0.rule.id, $0.rule) },
            uniquingKeysWith: { first, _ in first }
        )

        for (ruleID, rule) in live where !rule.watchedPaths.isEmpty {
            let watcher = watchers[ruleID] ?? makeWatcher()
            watchers[ruleID] = watcher
            watcher.watch(paths: rule.watchedPaths)
        }

        for (ruleID, watcher) in watchers where live[ruleID] == nil {
            watcher.stop()
            watchers[ruleID] = nil
        }
    }

    private func sampleTracked(at now: TimeInterval) {
        for (identity, var tracker) in trackers {
            switch tracker.rule.signal {
            case .cpu:
                guard let sample = sampler.sampleCPU(for: identity) else {
                    // The process exited, or its PID was reused by a different process.
                    trackers[identity] = nil
                    continue
                }
                tracker.record(sample: sample, at: now)
            case .fileActivity:
                // Still confirm the process is alive: file activity alone must not hold the Mac
                // awake once the tool has quit.
                guard sampler.sampleCPU(for: identity) != nil else {
                    trackers[identity] = nil
                    continue
                }
                tracker.record(lastFileChange: watchers[tracker.rule.id]?.lastChange, at: now)
            }
            tracker.tick(at: now)
            trackers[identity] = tracker
        }
    }
}
