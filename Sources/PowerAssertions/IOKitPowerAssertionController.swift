import Foundation
import IOKit.pwr_mgt

/// The real implementation, backed by IOKit power management.
///
/// Every assertion is created through `IOPMAssertionCreateWithProperties` with an explicit timeout
/// and `TimeoutActionRelease`, so `powerd` itself drops the assertion if this process dies, hangs,
/// or otherwise fails to re-arm. `IOPMAssertionCreateWithName` cannot express a timeout, which is
/// why it is not used here.
public struct IOKitPowerAssertionController: PowerAssertionControlling {
    public init() {}

    public func create(
        kind: AssertionKind,
        name: String,
        details: String?,
        timeout: TimeInterval
    ) throws -> PowerAssertionID {
        guard timeout > 0, timeout.isFinite else { throw InvalidTimeoutError(timeout: timeout) }

        var properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kind.ioKitType,
            kIOPMAssertionNameKey as String: name,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey as String: timeout,
            // IOKit defaults this to `TimeoutActionTurnOff`, which logs but leaves the assertion
            // in place. `Release` is what actually hands control back to the OS.
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease,
        ]
        if let details {
            properties[kIOPMAssertionDetailsKey as String] = details
        }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError(code: result, operation: "IOPMAssertionCreateWithProperties")
        }
        return PowerAssertionID(rawValue: id)
    }

    public func release(_ id: PowerAssertionID) throws {
        let result = IOPMAssertionRelease(IOPMAssertionID(id.rawValue))
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError(code: result, operation: "IOPMAssertionRelease")
        }
    }
}
