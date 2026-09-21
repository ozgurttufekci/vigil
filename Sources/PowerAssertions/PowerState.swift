import Foundation
import IOKit.ps

/// A snapshot of the machine's power situation.
public struct PowerState: Sendable, Equatable {
    /// `true` when running on mains power.
    public let isOnACPower: Bool
    /// Remaining charge, 0–100, or `nil` on a machine with no battery.
    public let batteryPercentage: Double?

    public init(isOnACPower: Bool, batteryPercentage: Double?) {
        self.isOnACPower = isOnACPower
        self.batteryPercentage = batteryPercentage
    }

    /// Whether holding the Mac awake is still reasonable under the given floor.
    ///
    /// Desktops and any machine without a battery are always allowed.
    public func allowsKeepingAwake(batteryFloor: Double) -> Bool {
        if isOnACPower { return true }
        guard let batteryPercentage else { return true }
        return batteryPercentage > batteryFloor
    }
}

/// Reads the current power source.
public protocol PowerStateReading: Sendable {
    func currentState() -> PowerState
}

/// The real implementation, backed by IOKit's power-source registry.
public struct IOKitPowerStateReader: PowerStateReading {
    public init() {}

    public func currentState() -> PowerState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            // No readable power source: treat as a desktop rather than silently refusing to work.
            return PowerState(isOnACPower: true, batteryPercentage: nil)
        }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }

            let isCharging =
                (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            if let current = description[kIOPSCurrentCapacityKey] as? Double,
                let max = description[kIOPSMaxCapacityKey] as? Double, max > 0
            {
                return PowerState(
                    isOnACPower: isCharging,
                    batteryPercentage: (current / max) * 100
                )
            }
            return PowerState(isOnACPower: isCharging, batteryPercentage: nil)
        }

        return PowerState(isOnACPower: true, batteryPercentage: nil)
    }
}
