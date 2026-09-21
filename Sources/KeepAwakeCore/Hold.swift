import Foundation

/// Why a hold exists.
///
/// The source is surfaced in the UI so the user can always see *what* is keeping the Mac awake.
public enum HoldSource: Sendable, Hashable {
    /// The user asked for it explicitly (menu bar, Control Center).
    case manual
    /// An auto-detect rule matched a running process.
    case rule(id: String)
    /// A command-line client requested a lease.
    case cli(pid: Int32)
}

/// A single reason to stay awake.
///
/// Holds stack: the coordinator keeps the Mac awake while *any* hold is active, and derives one
/// desired assertion state from the whole set rather than mapping holds onto assertions one-to-one.
public struct Hold: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let source: HoldSource
    /// Human-readable explanation, shown in the UI.
    ///
    /// Must never contain raw process arguments: command lines routinely carry API keys and tokens.
    public let reason: String
    /// Monotonic deadline, or `nil` for an indefinite hold.
    public let expiry: TimeInterval?
    /// Whether this hold also requires the display to stay awake.
    public let keepDisplayAwake: Bool
    /// Monotonic creation time.
    public let createdAt: TimeInterval

    public init(
        id: UUID = UUID(),
        source: HoldSource,
        reason: String,
        expiry: TimeInterval?,
        keepDisplayAwake: Bool,
        createdAt: TimeInterval
    ) {
        self.id = id
        self.source = source
        self.reason = reason
        self.expiry = expiry
        self.keepDisplayAwake = keepDisplayAwake
        self.createdAt = createdAt
    }

    public func isExpired(at now: TimeInterval) -> Bool {
        guard let expiry else { return false }
        return now >= expiry
    }

    /// Seconds left, or `nil` for an indefinite hold. Never negative.
    public func remaining(at now: TimeInterval) -> TimeInterval? {
        guard let expiry else { return nil }
        return max(0, expiry - now)
    }
}
