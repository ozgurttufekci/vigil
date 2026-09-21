import Foundation
import KeepAwakeCore
import MonotonicTime
import PowerAssertions
import ProcessWatch

/// What the menu bar should currently display.
struct VigilStatus {
    var isAwake: Bool
    var manualHold: Hold?
    var detections: [ActiveDetection]
    var batteryBlocked: Bool
    var remaining: TimeInterval?
}

/// Owns the engine, the detector, and the policy that connects them.
///
/// Confined to the main actor: every mutation arrives from the menu or from a main-run-loop timer,
/// so no locking is required.
@MainActor
final class VigilController {
    private let coordinator: KeepAwakeCoordinator
    private let detector: AutoDetectEngine
    private let powerReader: PowerStateReading
    private let settings: Settings
    private let clock: MonotonicClock

    /// Holds created by auto-detect, keyed by rule so one hold covers a rule's processes.
    private var automaticHolds: [String: Hold] = [:]
    private var manualHold: Hold?

    var onChange: (() -> Void)?

    init(
        coordinator: KeepAwakeCoordinator,
        detector: AutoDetectEngine,
        powerReader: PowerStateReading,
        settings: Settings,
        clock: MonotonicClock
    ) {
        self.coordinator = coordinator
        self.detector = detector
        self.powerReader = powerReader
        self.settings = settings
        self.clock = clock
    }

    var status: VigilStatus {
        VigilStatus(
            isAwake: coordinator.state != .idle,
            manualHold: manualHold,
            detections: settings.autoDetectEnabled ? detector.activeDetections : [],
            batteryBlocked: !isBatteryOK,
            remaining: coordinator.timeUntilNextExpiry
        )
    }

    var isManuallyActive: Bool { manualHold != nil }

    // MARK: - Manual control

    /// Starts a manual hold, replacing any existing one.
    ///
    /// - Parameter duration: `nil` keeps the Mac awake until explicitly stopped.
    func startManualHold(duration: TimeInterval?) {
        stopManualHold()
        let reason =
            duration.map { "Manual hold for \(Self.format(duration: $0))" }
            ?? "Manual hold until stopped"
        do {
            manualHold = try coordinator.add(
                source: .manual,
                reason: reason,
                duration: duration,
                keepDisplayAwake: settings.keepDisplayAwake
            )
        } catch {
            Log.error("Could not start manual hold: \(error)")
            manualHold = nil
        }
        notify()
    }

    func stopManualHold() {
        guard let hold = manualHold else { return }
        try? coordinator.remove(hold.id)
        manualHold = nil
        notify()
    }

    func toggleManualHold() {
        if manualHold == nil { startManualHold(duration: nil) } else { stopManualHold() }
    }

    /// Extends the current manual hold, or starts one if none is running.
    func extendManualHold(by duration: TimeInterval) {
        let existing = manualHold.flatMap { $0.remaining(at: clock.now) } ?? 0
        startManualHold(duration: existing + duration)
    }

    // MARK: - Periodic work

    /// Runs one cycle: expire holds, re-sample processes, apply policy. Call on a timer.
    func refresh() {
        do {
            let expired = try coordinator.refresh()
            if expired.contains(where: { $0.source == .manual }) {
                manualHold = nil
                Notifier.holdExpired()
            }
            // Drop internal references to automatic holds the coordinator has already expired.
            for (ruleID, hold) in automaticHolds where expired.contains(hold) {
                automaticHolds[ruleID] = nil
            }
        } catch {
            Log.error("Refresh failed: \(error)")
        }

        updateAutoDetect()
        enforceBatteryFloor()
        notify()
    }

    func reloadRules() {
        detector.rules = settings.effectiveRules
        if !settings.autoDetectEnabled {
            detector.reset()
            releaseAllAutomaticHolds()
        }
        notify()
    }

    func shutdown() {
        try? coordinator.shutdown()
        manualHold = nil
        automaticHolds.removeAll()
    }

    // MARK: - Policy

    private var isBatteryOK: Bool {
        let state = powerReader.currentState()
        if settings.pauseOnBattery && !state.isOnACPower { return false }
        return state.allowsKeepingAwake(batteryFloor: settings.batteryFloor)
    }

    private func updateAutoDetect() {
        guard settings.autoDetectEnabled else {
            releaseAllAutomaticHolds()
            return
        }

        detector.refresh()

        // The battery floor governs automatic holds only. A manual hold is an explicit instruction,
        // so silently cancelling it would be worse than the battery cost.
        guard isBatteryOK else {
            releaseAllAutomaticHolds()
            return
        }

        let active = Dictionary(
            grouping: detector.activeDetections,
            by: { $0.ruleID }
        )

        for (ruleID, detections) in active where automaticHolds[ruleID] == nil {
            guard let first = detections.first else { continue }
            // Reason text is built from the rule and process names only. Command lines are never
            // available here, by design.
            let reason =
                detections.count == 1
                ? "\(first.ruleName) is working (\(first.processName))"
                : "\(first.ruleName) is working (\(detections.count) processes)"
            do {
                automaticHolds[ruleID] = try coordinator.add(
                    source: .rule(id: ruleID),
                    reason: reason,
                    duration: nil,
                    keepDisplayAwake: settings.keepDisplayAwake
                )
            } catch {
                Log.error("Could not hold for rule \(ruleID): \(error)")
            }
        }

        for (ruleID, hold) in automaticHolds where active[ruleID] == nil {
            try? coordinator.remove(hold.id)
            automaticHolds[ruleID] = nil
        }
    }

    private func enforceBatteryFloor() {
        guard !isBatteryOK else { return }
        releaseAllAutomaticHolds()
    }

    private func releaseAllAutomaticHolds() {
        guard !automaticHolds.isEmpty else { return }
        for hold in automaticHolds.values {
            try? coordinator.remove(hold.id)
        }
        automaticHolds.removeAll()
    }

    private func notify() {
        onChange?()
    }

    static func format(duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
