import Foundation
import PowerAssertions

/// Drives the real power-assertion layer toward a desired state, and keeps a rolling watchdog armed.
///
/// ## Why a rolling watchdog
///
/// Every assertion is created with an OS-enforced timeout and `TimeoutActionRelease`. A healthy app
/// re-arms well before that timeout lapses. If this process crashes, hangs, or is force-killed,
/// `powerd` releases the assertion on its own and the Mac returns to normal sleep behaviour. The
/// machine can never be stranded awake by a bug in this app.
public final class AssertionReconciler {
    public struct Configuration: Sendable {
        /// Seconds after which the OS releases the assertion unless we re-arm.
        public let assertionTimeout: TimeInterval
        /// How often we re-arm. Always at most one third of `assertionTimeout`.
        public let rearmInterval: TimeInterval
        /// Assertion name, visible in `pmset -g assertions`.
        public let name: String

        /// - Parameters:
        ///   - assertionTimeout: Clamped to a sane floor; a very short timeout would cause churn.
        ///     Non-finite values fall back to the default.
        ///   - rearmInterval: Defaults to a third of the timeout, and is clamped so it can never
        ///     exceed that. A third rather than a half because at a half, one missed tick lands the
        ///     next attempt exactly on the timeout deadline, where scheduling latency or timer
        ///     coalescing could still leave an unprotected gap.
        public init(
            assertionTimeout: TimeInterval = 600,
            rearmInterval: TimeInterval? = nil,
            name: String
        ) {
            let timeout = max(assertionTimeout.isFinite ? assertionTimeout : 600, 10)
            self.assertionTimeout = timeout
            let ceiling = timeout / 3
            let requested = rearmInterval.flatMap { $0.isFinite ? $0 : nil } ?? ceiling
            self.rearmInterval = min(max(requested, 1), ceiling)
            self.name = name
        }
    }

    private struct Armed {
        let id: PowerAssertionID
        let armedAt: TimeInterval
    }

    private let controller: PowerAssertionControlling
    private let clock: MonotonicClock
    private let configuration: Configuration
    private var armed: [AssertionKind: Armed] = [:]
    /// Assertions we failed to release, mapped to the deadline by which the OS will have dropped
    /// them anyway. Retried opportunistically so "turn it off" really does turn it off.
    private var retiring: [PowerAssertionID: TimeInterval] = [:]

    public init(
        controller: PowerAssertionControlling,
        clock: MonotonicClock,
        configuration: Configuration
    ) {
        self.controller = controller
        self.clock = clock
        self.configuration = configuration
    }

    /// Assertion kinds currently held, for diagnostics and tests.
    public var activeKinds: Set<AssertionKind> {
        Set(armed.keys)
    }

    /// Assertions that could not be released and are awaiting retry or OS timeout.
    public var retiringCount: Int {
        retiring.count
    }

    /// Brings real assertion state in line with `desired`, and re-arms anything due.
    ///
    /// Reconciling and re-arming are deliberately a single operation. When they were separate, an
    /// `apply` that ran after the OS had already timed out an assertion would see a stale tracking
    /// entry, assume the assertion was still live, and skip creating a replacement — leaving the app
    /// believing it held protection it did not.
    public func reconcile(to desired: DesiredAssertionState, details: String? = nil) throws {
        let now = clock.now
        let needed: Set<AssertionKind> =
            switch desired {
            case .idle:
                []
            case .awake(let keepDisplayAwake):
                keepDisplayAwake
                    ? [.preventIdleSystemSleep, .preventIdleDisplaySleep]
                    : [.preventIdleSystemSleep]
            }

        retryRetirements(now: now)

        for (kind, entry) in armed where !needed.contains(kind) {
            armed[kind] = nil
            retire(entry)
        }

        for kind in needed {
            guard let entry = armed[kind] else {
                let id = try controller.create(
                    kind: kind,
                    name: configuration.name,
                    details: details,
                    timeout: configuration.assertionTimeout
                )
                armed[kind] = Armed(id: id, armedAt: now)
                continue
            }

            guard now - entry.armedAt >= configuration.rearmInterval else { continue }

            // Create the replacement *before* releasing the old one. Releasing first would leave a
            // window, however brief, in which the Mac is unprotected and could begin idle sleep.
            let replacement = try controller.create(
                kind: kind,
                name: configuration.name,
                details: details,
                timeout: configuration.assertionTimeout
            )
            armed[kind] = Armed(id: replacement, armedAt: now)
            retire(entry)
        }
    }

    /// Releases everything. Used on quit.
    public func releaseAll() throws {
        try reconcile(to: .idle)
    }

    /// Attempts to release an assertion we no longer want, parking it for retry if that fails.
    private func retire(_ entry: Armed) {
        do {
            try controller.release(entry.id)
        } catch {
            // Bounded, not leaked: the OS-enforced timeout will drop it even if every retry fails.
            retiring[entry.id] = entry.armedAt + configuration.assertionTimeout
        }
    }

    private func retryRetirements(now: TimeInterval) {
        for (id, deadline) in retiring {
            guard now < deadline else {
                // The OS has released it for us by now.
                retiring[id] = nil
                continue
            }
            if (try? controller.release(id)) != nil {
                retiring[id] = nil
            }
        }
    }
}
