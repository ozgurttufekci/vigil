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
        /// How often we re-arm. Always at most half of `assertionTimeout`.
        public let rearmInterval: TimeInterval
        /// Assertion name, visible in `pmset -g assertions`.
        public let name: String

        /// - Parameters:
        ///   - assertionTimeout: Clamped to a sane floor; a very short timeout would cause churn.
        ///   - rearmInterval: Defaults to half the timeout. Clamped so that it never exceeds half
        ///     the timeout, which guarantees that even one entirely missed re-arm tick cannot let
        ///     the assertion lapse.
        public init(
            assertionTimeout: TimeInterval = 600,
            rearmInterval: TimeInterval? = nil,
            name: String
        ) {
            let timeout = max(assertionTimeout, 10)
            self.assertionTimeout = timeout
            let requested = rearmInterval ?? timeout / 2
            self.rearmInterval = min(max(requested, 1), timeout / 2)
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

    /// Brings the real assertion state in line with `desired`.
    public func apply(_ desired: DesiredAssertionState, details: String? = nil) throws {
        let needed: Set<AssertionKind> =
            switch desired {
            case .idle:
                []
            case .awake(let keepDisplayAwake):
                keepDisplayAwake
                    ? [.preventIdleSystemSleep, .preventIdleDisplaySleep]
                    : [.preventIdleSystemSleep]
            }

        for kind in needed where armed[kind] == nil {
            let id = try controller.create(
                kind: kind,
                name: configuration.name,
                details: details,
                timeout: configuration.assertionTimeout
            )
            armed[kind] = Armed(id: id, armedAt: clock.uptime)
        }

        for (kind, entry) in armed where !needed.contains(kind) {
            // Stop tracking even if the release call fails: we must not retain a handle we cannot
            // act on. The OS-enforced timeout guarantees the assertion still goes away.
            armed[kind] = nil
            try controller.release(entry.id)
        }
    }

    /// Re-arms any assertion that is approaching its timeout. Call periodically.
    public func tick(details: String? = nil) throws {
        let now = clock.uptime
        for (kind, entry) in armed where now - entry.armedAt >= configuration.rearmInterval {
            // Create the replacement *before* releasing the old one. Releasing first would leave a
            // window, however brief, in which the Mac is unprotected and could begin idle sleep.
            let replacement = try controller.create(
                kind: kind,
                name: configuration.name,
                details: details,
                timeout: configuration.assertionTimeout
            )
            try? controller.release(entry.id)
            armed[kind] = Armed(id: replacement, armedAt: now)
        }
    }

    /// Releases everything. Used on quit.
    public func releaseAll() throws {
        try apply(.idle)
    }
}
