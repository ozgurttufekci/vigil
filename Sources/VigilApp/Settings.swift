import Foundation
import ProcessWatch

/// User preferences, persisted in `UserDefaults`.
///
/// Defaults are chosen to favour battery life: system sleep is blocked but the display is still
/// allowed to sleep, and automatic holds are dropped when the battery gets low.
@MainActor
final class Settings {
    private enum Key {
        static let keepDisplayAwake = "keepDisplayAwake"
        static let autoDetectEnabled = "autoDetectEnabled"
        static let batteryFloor = "batteryFloor"
        static let pauseOnBattery = "pauseOnBattery"
        static let showCountdown = "showCountdown"
        static let disabledRuleIDs = "disabledRuleIDs"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.keepDisplayAwake: false,
            Key.autoDetectEnabled: true,
            Key.batteryFloor: 20.0,
            Key.pauseOnBattery: false,
            Key.showCountdown: false,
            Key.disabledRuleIDs: [String](),
        ])
    }

    /// Whether to also prevent the display from sleeping.
    ///
    /// Off by default: the display dominates power draw, and background work runs fine without it.
    var keepDisplayAwake: Bool {
        get { defaults.bool(forKey: Key.keepDisplayAwake) }
        set { defaults.set(newValue, forKey: Key.keepDisplayAwake) }
    }

    var autoDetectEnabled: Bool {
        get { defaults.bool(forKey: Key.autoDetectEnabled) }
        set { defaults.set(newValue, forKey: Key.autoDetectEnabled) }
    }

    /// Battery percentage below which automatic holds are released.
    var batteryFloor: Double {
        get { defaults.double(forKey: Key.batteryFloor) }
        set { defaults.set(newValue, forKey: Key.batteryFloor) }
    }

    /// Whether auto-detect should hold the Mac awake only while on mains power.
    var pauseOnBattery: Bool {
        get { defaults.bool(forKey: Key.pauseOnBattery) }
        set { defaults.set(newValue, forKey: Key.pauseOnBattery) }
    }

    var showCountdown: Bool {
        get { defaults.bool(forKey: Key.showCountdown) }
        set { defaults.set(newValue, forKey: Key.showCountdown) }
    }

    private var disabledRuleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.disabledRuleIDs) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.disabledRuleIDs) }
    }

    func isRuleEnabled(_ rule: ProcessRule) -> Bool {
        rule.isEnabled && !disabledRuleIDs.contains(rule.id)
    }

    func setRule(_ rule: ProcessRule, enabled: Bool) {
        var ids = disabledRuleIDs
        if enabled { ids.remove(rule.id) } else { ids.insert(rule.id) }
        disabledRuleIDs = ids
    }

    /// Presets with the user's enable/disable choices applied.
    var effectiveRules: [ProcessRule] {
        ProcessRule.presets.map { preset in
            ProcessRule(
                id: preset.id,
                displayName: preset.displayName,
                commandLinePatterns: preset.commandLinePatterns,
                signal: preset.signal,
                gracePeriod: preset.gracePeriod,
                isEnabled: isRuleEnabled(preset)
            )
        }
    }
}
