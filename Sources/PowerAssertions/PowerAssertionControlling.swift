import Foundation

/// An opaque handle to a live power assertion.
public struct PowerAssertionID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// A failure returned by the power-management subsystem.
public struct PowerAssertionError: Error, Equatable, Sendable {
    /// The `IOReturn` code reported by IOKit.
    public let code: Int32
    /// The operation that failed, for diagnostics.
    public let operation: String

    public init(code: Int32, operation: String) {
        self.code = code
        self.operation = operation
    }
}

/// Thrown when a caller requests a timeout that is not finite and positive.
///
/// A zero timeout means "never time out" to IOKit, and an infinite or NaN one is not a bounded
/// watchdog at all. Either would defeat the guarantee that a crashed or hung app cannot strand the
/// machine awake, so they are rejected at the boundary.
public struct InvalidTimeoutError: Error, Equatable, Sendable {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }
}

/// Creates and releases power assertions.
///
/// Abstracted so the reconciler can be tested against a fake without touching real system power
/// state.
public protocol PowerAssertionControlling: Sendable {
    /// Creates a power assertion that the OS will automatically release after `timeout` seconds.
    ///
    /// - Parameter timeout: Seconds until power management releases the assertion on our behalf.
    ///   Must be greater than zero.
    func create(
        kind: AssertionKind,
        name: String,
        details: String?,
        timeout: TimeInterval
    ) throws -> PowerAssertionID

    /// Releases a previously created assertion.
    func release(_ id: PowerAssertionID) throws
}
