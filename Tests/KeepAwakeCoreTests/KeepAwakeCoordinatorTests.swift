import Foundation
import KeepAwakeCore
import PowerAssertions
import TestSupport
import Testing

@Suite("KeepAwakeCoordinator")
struct KeepAwakeCoordinatorTests {
    private func makeSUT() -> (KeepAwakeCoordinator, FakePowerAssertionController, ManualClock) {
        let clock = ManualClock()
        let controller = FakePowerAssertionController()
        let reconciler = AssertionReconciler(
            controller: controller,
            clock: clock,
            configuration: .init(assertionTimeout: 600, rearmInterval: 300, name: "Vigil")
        )
        return (KeepAwakeCoordinator(reconciler: reconciler, clock: clock), controller, clock)
    }

    @Test("Adding a hold takes a real assertion immediately")
    func addingAHoldAssertsImmediately() throws {
        let (sut, controller, _) = makeSUT()

        try sut.add(source: .manual, reason: "Coffee", duration: 1800)

        #expect(sut.state == .awake(keepDisplayAwake: false))
        #expect(controller.liveIDs.count == 1)
    }

    @Test("Removing the last hold releases the assertion")
    func removingLastHoldReleases() throws {
        let (sut, controller, _) = makeSUT()
        let hold = try sut.add(source: .manual, reason: "Coffee", duration: 1800)

        try sut.remove(hold.id)

        #expect(sut.state == .idle)
        #expect(controller.liveIDs.isEmpty)
    }

    @Test("An expired hold is dropped on refresh and reported back")
    func refreshReportsExpiredHolds() throws {
        let (sut, controller, clock) = makeSUT()
        try sut.add(source: .manual, reason: "30 minutes", duration: 1800)

        clock.advance(by: 1800)
        let expired = try sut.refresh()

        #expect(expired.map(\.reason) == ["30 minutes"])
        #expect(sut.state == .idle)
        #expect(controller.liveIDs.isEmpty)
    }

    @Test("A longer hold survives a shorter one expiring")
    func overlappingHoldsKeepTheMacAwake() throws {
        let (sut, controller, clock) = makeSUT()
        try sut.add(source: .manual, reason: "short", duration: 600)
        try sut.add(source: .rule(id: "copilot"), reason: "Copilot is working", duration: 3600)

        clock.advance(by: 900)
        let expired = try sut.refresh()

        #expect(expired.map(\.reason) == ["short"])
        #expect(sut.state == .awake(keepDisplayAwake: false))
        #expect(!controller.liveIDs.isEmpty)
    }

    @Test("Refreshing re-arms the watchdog on a long-running hold")
    func refreshRearmsWatchdog() throws {
        let (sut, controller, clock) = makeSUT()
        try sut.add(source: .manual, reason: "indefinite", duration: nil)
        let original = try #require(controller.creates.first?.id)

        clock.advance(by: 300)
        try sut.refresh()

        #expect(!controller.liveIDs.contains(original))
        #expect(controller.liveIDs.count == 1)
    }

    @Test("An indefinite hold still carries an OS-enforced timeout")
    func indefiniteHoldsAreStillWatchdogged() throws {
        let (sut, controller, _) = makeSUT()

        try sut.add(source: .manual, reason: "until I stop it", duration: nil)

        #expect(controller.creates.allSatisfy { $0.timeout == 600 })
    }

    @Test("Removing holds by predicate releases when the last one goes")
    func removeAllByPredicate() throws {
        let (sut, controller, _) = makeSUT()
        try sut.add(source: .rule(id: "copilot"), reason: "Copilot is working", duration: nil)
        try sut.add(source: .manual, reason: "manual", duration: nil)

        let removed = try sut.removeAll { $0.source == .rule(id: "copilot") }

        #expect(removed.count == 1)
        #expect(sut.state == .awake(keepDisplayAwake: false))

        try sut.removeAll { $0.source == .manual }
        #expect(sut.state == .idle)
        #expect(controller.liveIDs.isEmpty)
    }

    @Test("A hold that fails to activate is rolled back instead of being left orphaned")
    func failedAddIsRolledBack() throws {
        // Without rollback the hold would stay in storage while the caller held no handle to it,
        // and a later successful refresh would re-arm it forever with no way to cancel.
        let (sut, controller, _) = makeSUT()
        controller.failNextCreate(with: PowerAssertionError(code: -1, operation: "test"))

        #expect(throws: PowerAssertionError.self) {
            try sut.add(source: .manual, reason: "doomed", duration: nil)
        }

        #expect(sut.activeHolds.isEmpty)
        #expect(sut.state == .idle)

        try sut.refresh()
        #expect(controller.liveIDs.isEmpty)
    }

    @Test("A failed add leaves an existing hold untouched")
    func failedAddDoesNotDisturbExistingHolds() throws {
        let (sut, controller, _) = makeSUT()
        try sut.add(source: .manual, reason: "keeper", duration: nil)
        controller.failNextCreate(with: PowerAssertionError(code: -1, operation: "test"))

        #expect(throws: PowerAssertionError.self) {
            try sut.add(source: .manual, reason: "doomed", duration: nil, keepDisplayAwake: true)
        }

        #expect(sut.activeHolds.map(\.reason) == ["keeper"])
        #expect(sut.state == .awake(keepDisplayAwake: false))
        #expect(!controller.liveIDs.isEmpty)
    }

    @Test("Shutting down releases everything")
    func shutdownReleasesEverything() throws {
        let (sut, controller, _) = makeSUT()
        try sut.add(source: .manual, reason: "a", duration: nil)
        try sut.add(source: .manual, reason: "b", duration: nil, keepDisplayAwake: true)

        try sut.shutdown()

        #expect(sut.state == .idle)
        #expect(controller.liveIDs.isEmpty)
        #expect(sut.activeHolds.isEmpty)
    }

    @Test("The countdown reflects the soonest deadline")
    func timeUntilNextExpiry() throws {
        let (sut, _, clock) = makeSUT()
        try sut.add(source: .manual, reason: "long", duration: 3600)
        try sut.add(source: .manual, reason: "short", duration: 900)

        clock.advance(by: 300)

        #expect(sut.timeUntilNextExpiry == 600)
    }

    @Test("A negative duration is treated as immediately expired rather than reversing time")
    func negativeDurationDoesNotCreateAPastHold() throws {
        let (sut, _, _) = makeSUT()

        try sut.add(source: .manual, reason: "oops", duration: -500)

        #expect(sut.state == .idle)
    }

    @Test("The assertion's visible details describe the reason, so pmset shows why")
    func detailsExplainWhy() throws {
        let (sut, controller, _) = makeSUT()

        try sut.add(source: .rule(id: "copilot"), reason: "Copilot is working", duration: nil)

        #expect(controller.creates.first?.details == "Copilot is working")
    }

    @Test("Multiple holds summarise without leaking every reason string")
    func detailsSummariseMultipleHolds() throws {
        let (sut, controller, _) = makeSUT()
        try sut.add(source: .manual, reason: "first", duration: nil)
        controller.reset()

        // Forcing a new assertion kind makes the reconciler create one with current details.
        try sut.add(source: .manual, reason: "second", duration: nil, keepDisplayAwake: true)

        let details = try #require(controller.creates.first?.details)
        #expect(details.contains("more"))
    }
}
