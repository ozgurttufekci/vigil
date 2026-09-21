import Foundation

/// The top-level engine: owns the set of holds and keeps real power state in sync with it.
///
/// Not thread-safe by design. The app drives it from the main run loop; the CLI bridge marshals
/// onto that same loop.
public final class KeepAwakeCoordinator {
    private let reconciler: AssertionReconciler
    private let clock: MonotonicClock
    private var holds = HoldSet()

    public init(reconciler: AssertionReconciler, clock: MonotonicClock) {
        self.reconciler = reconciler
        self.clock = clock
    }

    public var activeHolds: [Hold] {
        holds.active(at: clock.uptime)
    }

    public var state: DesiredAssertionState {
        holds.desiredState(at: clock.uptime)
    }

    /// Seconds until the soonest hold expires, or `nil` if nothing is scheduled to expire.
    public var timeUntilNextExpiry: TimeInterval? {
        let now = clock.uptime
        guard let next = holds.nextExpiry(at: now) else { return nil }
        return max(0, next - now)
    }

    /// Adds a hold and immediately reconciles power state.
    ///
    /// - Parameters:
    ///   - reason: Shown in the UI and in `pmset -g assertions`. Must not contain process
    ///     arguments, which routinely carry secrets.
    ///   - duration: `nil` creates an indefinite hold. Indefinite holds are still protected by the
    ///     reconciler's OS-enforced watchdog.
    @discardableResult
    public func add(
        source: HoldSource,
        reason: String,
        duration: TimeInterval?,
        keepDisplayAwake: Bool = false
    ) throws -> Hold {
        let now = clock.uptime
        let hold = Hold(
            source: source,
            reason: reason,
            expiry: duration.map { now + max(0, $0) },
            keepDisplayAwake: keepDisplayAwake,
            createdAt: now
        )
        holds.insert(hold)
        try reconcile()
        return hold
    }

    public func remove(_ id: UUID) throws {
        holds.remove(id)
        try reconcile()
    }

    /// Removes every hold from a given source, e.g. when an auto-detect rule stops matching.
    @discardableResult
    public func removeAll(where shouldRemove: (Hold) -> Bool) throws -> [Hold] {
        let removed = holds.removeAll(where: shouldRemove)
        try reconcile()
        return removed
    }

    /// Prunes expired holds, reconciles, and re-arms the watchdog. Call on a timer.
    ///
    /// - Returns: Holds that expired during this call, so the caller can notify the user.
    @discardableResult
    public func refresh() throws -> [Hold] {
        let expired = holds.pruneExpired(at: clock.uptime)
        try reconcile()
        try reconciler.tick(details: currentDetails)
        return expired
    }

    /// Releases all power assertions. Call on quit.
    public func shutdown() throws {
        holds = HoldSet()
        try reconciler.releaseAll()
    }

    private func reconcile() throws {
        try reconciler.apply(holds.desiredState(at: clock.uptime), details: currentDetails)
    }

    /// A short, secret-free summary of why the Mac is awake.
    private var currentDetails: String? {
        let live = holds.active(at: clock.uptime)
        guard let first = live.first else { return nil }
        return live.count == 1 ? first.reason : "\(first.reason) (+\(live.count - 1) more)"
    }
}
