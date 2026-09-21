import Foundation
import Testing

@testable import PowerAssertions

@Suite("AssertionKind")
struct AssertionKindTests {
    @Test("Maps to the IOKit type strings powerd expects")
    func ioKitTypeStrings() {
        #expect(AssertionKind.preventIdleSystemSleep.ioKitType == "PreventUserIdleSystemSleep")
        #expect(AssertionKind.preventIdleDisplaySleep.ioKitType == "PreventUserIdleDisplaySleep")
    }

    @Test("Does not expose the deprecated, non-functional PreventSystemSleep type")
    func doesNotOfferDeprecatedType() {
        // Apple deprecated `PreventSystemSleep` in 10.9 and it is not honoured on any modern
        // release. Offering it would silently fail to keep the Mac awake.
        #expect(!AssertionKind.allCases.map(\.ioKitType).contains("PreventSystemSleep"))
    }
}

@Suite("IOKitPowerAssertionController")
struct IOKitPowerAssertionControllerTests {
    /// Reads the live system assertion table.
    private func pmsetAssertions() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("A zero or negative timeout is rejected, because IOKit reads it as 'never time out'")
    func rejectsNonPositiveTimeout() {
        let sut = IOKitPowerAssertionController()

        #expect(throws: InvalidTimeoutError.self) {
            try sut.create(kind: .preventIdleSystemSleep, name: "t", details: nil, timeout: 0)
        }
        #expect(throws: InvalidTimeoutError.self) {
            try sut.create(kind: .preventIdleSystemSleep, name: "t", details: nil, timeout: -1)
        }
    }

    @Test("Infinite and NaN timeouts are rejected, because they are not a bounded watchdog")
    func rejectsNonFiniteTimeout() {
        let sut = IOKitPowerAssertionController()

        #expect(throws: InvalidTimeoutError.self) {
            try sut.create(
                kind: .preventIdleSystemSleep, name: "t", details: nil, timeout: .infinity
            )
        }
        #expect(throws: InvalidTimeoutError.self) {
            try sut.create(kind: .preventIdleSystemSleep, name: "t", details: nil, timeout: .nan)
        }
    }

    @Test("A real assertion becomes visible to the system and disappears when released")
    func assertionIsVisibleToPmset() throws {
        let sut = IOKitPowerAssertionController()
        let name = "Vigil integration test \(UUID().uuidString)"

        let id = try sut.create(
            kind: .preventIdleSystemSleep,
            name: name,
            details: "unit test",
            timeout: 30
        )
        #expect(try pmsetAssertions().contains(name))

        try sut.release(id)
        #expect(try !pmsetAssertions().contains(name))
    }

    @Test("The OS releases the assertion on its own when the timeout lapses")
    func osEnforcesTheTimeout() throws {
        // This is the safety guarantee the whole design rests on: if this app crashes or hangs
        // without releasing, powerd drops the assertion and the Mac sleeps normally again.
        let sut = IOKitPowerAssertionController()
        let name = "Vigil watchdog test \(UUID().uuidString)"

        _ = try sut.create(
            kind: .preventIdleSystemSleep,
            name: name,
            details: "watchdog",
            timeout: 2
        )
        #expect(try pmsetAssertions().contains(name))

        // Deliberately never released: the OS must clean it up for us.
        Thread.sleep(forTimeInterval: 5)

        #expect(try !pmsetAssertions().contains(name))
    }
}
