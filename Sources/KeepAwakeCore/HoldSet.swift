import Foundation

/// What the power-management layer should be doing right now.
public enum DesiredAssertionState: Sendable, Equatable {
    /// Nothing is holding the Mac awake; normal sleep behaviour applies.
    case idle
    /// Keep the Mac awake, optionally keeping the display awake too.
    case awake(keepDisplayAwake: Bool)
}

/// The live set of holds, and the single source of truth for what the Mac should do.
public struct HoldSet: Sendable, Equatable {
    private var storage: [UUID: Hold] = [:]

    public init() {}

    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }

    /// All holds, newest first, regardless of expiry.
    public var all: [Hold] {
        storage.values.sorted { $0.createdAt > $1.createdAt }
    }

    public mutating func insert(_ hold: Hold) {
        storage[hold.id] = hold
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> Hold? {
        storage.removeValue(forKey: id)
    }

    @discardableResult
    public mutating func removeAll(where shouldRemove: (Hold) -> Bool) -> [Hold] {
        let doomed = storage.values.filter(shouldRemove)
        for hold in doomed { storage.removeValue(forKey: hold.id) }
        return doomed
    }

    /// Holds that have not yet expired, newest first.
    public func active(at uptime: TimeInterval) -> [Hold] {
        storage.values
            .filter { !$0.isExpired(at: uptime) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Drops expired holds and returns them, so the caller can notify the user.
    @discardableResult
    public mutating func pruneExpired(at uptime: TimeInterval) -> [Hold] {
        removeAll { $0.isExpired(at: uptime) }
    }

    /// The state the power-management layer should be reconciled to.
    ///
    /// The display is kept awake only if at least one active hold explicitly asks for it, so a
    /// display-awake hold expiring downgrades to system-only rather than dropping protection
    /// entirely.
    public func desiredState(at uptime: TimeInterval) -> DesiredAssertionState {
        let live = active(at: uptime)
        guard !live.isEmpty else { return .idle }
        return .awake(keepDisplayAwake: live.contains { $0.keepDisplayAwake })
    }

    /// The soonest deadline among active holds, used to schedule the next wake-up.
    ///
    /// `nil` when nothing is active or every active hold is indefinite.
    public func nextExpiry(at uptime: TimeInterval) -> TimeInterval? {
        active(at: uptime).compactMap(\.expiry).min()
    }
}
