import Foundation
import KeepAwakeCore
import PowerAssertions
import Testing

@Suite("AssertionReconciler")
struct AssertionReconcilerTests {
    private func makeSUT(
        assertionTimeout: TimeInterval = 600,
        rearmInterval: TimeInterval? = nil
    ) -> (AssertionReconciler, FakePowerAssertionController, ManualClock) {
        let clock = ManualClock()
        let controller = FakePowerAssertionController()
        let reconciler = AssertionReconciler(
            controller: controller,
            clock: clock,
            configuration: .init(
                assertionTimeout: assertionTimeout,
                rearmInterval: rearmInterval,
                name: "Vigil test"
            )
        )
        return (reconciler, controller, clock)
    }

    // MARK: - Reconciling to desired state

    @Test("Staying awake takes only a system assertion, leaving the display free to sleep")
    func systemOnlyByDefault() throws {
        let (sut, controller, _) = makeSUT()

        try sut.apply(.awake(keepDisplayAwake: false))

        #expect(sut.activeKinds == [.preventIdleSystemSleep])
        #expect(controller.creates.map(\.kind) == [.preventIdleSystemSleep])
    }

    @Test("Keeping the display awake takes both assertions")
    func displayTakesBothAssertions() throws {
        let (sut, controller, _) = makeSUT()

        try sut.apply(.awake(keepDisplayAwake: true))

        #expect(sut.activeKinds == [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        #expect(controller.creates.count == 2)
    }

    @Test("Going idle releases every assertion")
    func idleReleasesEverything() throws {
        let (sut, controller, _) = makeSUT()
        try sut.apply(.awake(keepDisplayAwake: true))

        try sut.apply(.idle)

        #expect(sut.activeKinds.isEmpty)
        #expect(controller.liveIDs.isEmpty)
    }

    @Test("Dropping the display requirement keeps the system assertion alive")
    func downgradeReleasesOnlyDisplay() throws {
        let (sut, controller, _) = makeSUT()
        try sut.apply(.awake(keepDisplayAwake: true))
        let systemID = try #require(
            controller.creates.first { $0.kind == .preventIdleSystemSleep }?.id
        )
        let displayID = try #require(
            controller.creates.first { $0.kind == .preventIdleDisplaySleep }?.id
        )

        try sut.apply(.awake(keepDisplayAwake: false))

        #expect(sut.activeKinds == [.preventIdleSystemSleep])
        #expect(controller.liveIDs.contains(systemID))
        #expect(!controller.liveIDs.contains(displayID))
    }

    @Test("Re-applying the same state does not churn assertions")
    func applyIsIdempotent() throws {
        let (sut, controller, _) = makeSUT()

        try sut.apply(.awake(keepDisplayAwake: false))
        try sut.apply(.awake(keepDisplayAwake: false))
        try sut.apply(.awake(keepDisplayAwake: false))

        #expect(controller.creates.count == 1)
    }

    // MARK: - Watchdog safety

    @Test("Every assertion carries a positive OS-enforced timeout")
    func assertionsAlwaysHaveATimeout() throws {
        let (sut, controller, _) = makeSUT(assertionTimeout: 600)

        try sut.apply(.awake(keepDisplayAwake: true))

        #expect(controller.creates.allSatisfy { $0.timeout == 600 })
        #expect(controller.creates.allSatisfy { $0.timeout > 0 })
    }

    @Test("Re-arming creates the replacement before releasing the old assertion")
    func rearmOverlapsSoThereIsNeverAnUnprotectedWindow() throws {
        let (sut, controller, clock) = makeSUT(assertionTimeout: 600, rearmInterval: 300)
        try sut.apply(.awake(keepDisplayAwake: false))
        let original = try #require(controller.creates.first?.id)
        controller.reset()

        clock.advance(by: 300)
        try sut.tick()

        // Ordering is the safety property: releasing first would leave an instant in which the
        // Mac is unprotected and could begin idle sleep.
        #expect(controller.events.count == 2)
        guard case .create(let replacement) = controller.events.first else {
            Issue.record("Expected a create as the first event, got \(controller.events)")
            return
        }
        #expect(controller.events.last == .release(original))
        #expect(replacement.id != original)
        #expect(controller.liveIDs == [replacement.id])
    }

    @Test("Ticking before the re-arm interval does nothing")
    func tickIsQuietUntilRearmIsDue() throws {
        let (sut, controller, clock) = makeSUT(assertionTimeout: 600, rearmInterval: 300)
        try sut.apply(.awake(keepDisplayAwake: false))
        controller.reset()

        clock.advance(by: 299)
        try sut.tick()

        #expect(controller.events.isEmpty)
    }

    @Test("Ticking while idle does nothing")
    func tickWhileIdleDoesNothing() throws {
        let (sut, controller, clock) = makeSUT()

        clock.advance(by: 10_000)
        try sut.tick()

        #expect(controller.events.isEmpty)
    }

    @Test(
        "Re-arm interval never exceeds half the timeout, so one missed tick cannot strand us",
        arguments: [
            (600.0, TimeInterval?.none),
            (600.0, TimeInterval?.some(9_999)),
            (600.0, TimeInterval?.some(0)),
            (10.0, TimeInterval?.some(600)),
            (1.0, TimeInterval?.none),
        ]
    )
    func rearmIntervalIsClamped(timeout: TimeInterval, requested: TimeInterval?) {
        let configuration = AssertionReconciler.Configuration(
            assertionTimeout: timeout,
            rearmInterval: requested,
            name: "Vigil test"
        )

        #expect(configuration.rearmInterval > 0)
        #expect(configuration.rearmInterval * 2 <= configuration.assertionTimeout)
    }

    @Test("A failed release still stops tracking, letting the OS timeout clean up")
    func failedReleaseDoesNotLeakAHandle() throws {
        let (sut, controller, _) = makeSUT()
        try sut.apply(.awake(keepDisplayAwake: false))
        controller.failNextRelease(with: PowerAssertionError(code: -1, operation: "test"))

        #expect(throws: PowerAssertionError.self) {
            try sut.apply(.idle)
        }
        #expect(sut.activeKinds.isEmpty)
    }
}
