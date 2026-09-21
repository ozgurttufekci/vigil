import Foundation

/// The kind of sleep an assertion prevents.
///
/// Deliberately omits `PreventSystemSleep`: that assertion type was deprecated in macOS 10.9 and,
/// per Apple's `IOPMLib.h`, "is not supported in any OS X releases". Taking it would silently do
/// nothing, which is the worst possible failure mode for this app.
public enum AssertionKind: String, Sendable, CaseIterable {
    /// Prevents idle *system* sleep while still allowing the display to sleep.
    ///
    /// This is the default for background work: the display is the dominant power draw, and a
    /// background agent keeps running fine with the screen off.
    case preventIdleSystemSleep

    /// Prevents the display from dimming and sleeping.
    ///
    /// Per `IOPMLib.h`, while the display is prevented from sleeping the system also cannot idle
    /// sleep. We still take a system assertion alongside this one rather than relying on that
    /// implied behaviour.
    case preventIdleDisplaySleep

    /// The raw IOKit assertion type string.
    public var ioKitType: String {
        switch self {
        case .preventIdleSystemSleep: "PreventUserIdleSystemSleep"
        case .preventIdleDisplaySleep: "PreventUserIdleDisplaySleep"
        }
    }
}
