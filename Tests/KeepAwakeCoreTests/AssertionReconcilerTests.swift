import Foundation
import KeepAwakeCore
import PowerAssertions
import TestSupport
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

        try sut.reconcile(to: .awake(keepDisplayAwake: false))

        #expect(sut.activeKinds == [.preventIdleSystemSleep])
        #expect(controller.creates.map(\.kind) == [.preventIdleSystemSleep])
    }

    @Test("Keeping the display awake takes both assertions")
    func displayTakesBothAssertions() throws {
        let (sut, controller, _) = makeSUT()

        try sut.reconcile(to: .awake(keepDisplayAwake: true))

        #expect(sut.activeKinds == [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        #expect(controller.creates.count == 2)
    }

    @Test("Going idle releases every assertion")
    func idleReleasesEverything() throws {
        let (sut, controller, _) = makeSUT()
        try sut.reconcile(to: .awake(keepDisplayAwake: true))

        try sut.reconcile(to: .idle)

        #expect(sut.activeKinds.isEmpty)
        #expect(controller.liveIDs.isEmpty)
    }

    @Test("Dropping the display requirement keeps the system assertion alive")
    func downgradeReleasesOnlyDisplay() throws {
        let (sut, controller, _) = makeSUT()
        try sut.reconcile(to: .awake(keepDisplayAwake: true))
        let systemID = try #require(
            controller.creates.first { $0.kind == .preventIdleSystemSleep }?.id
        )
        let displayID = try #require(
            controller.creates.first { $0.kind == .preventIdleDisplaySleep }?.id
        )

        try sut.reconcile(to: .awake(keepDisplayAwake: false))

        #expect(sut.activeKinds == [.preventIdleSystemSleep])
        #expect(controller.liveIDs.contains(systemID))
        #expect(!controller.liveIDs.contains(displayID))
    }

    @Test("Re-reconciling to the same state does not churn assertions")
    func reconcileIsIdempotent() throws {
        let (sut, controller, _) = makeSUT()

        try sut.reconcile(to: .awake(keepDisplayAwake: false))
        try sut.reconcile(to: .awake(keepDisplayAwake: false))
        try sut.reconcile(to: .awake(keepDisplayAwake: false))

        #expect(controller.creates.count == 1)
    }

    // MARK: - Watchdog safety

    @Test("Every assertion carries a positive OS-enforced timeout")
    func assertionsAlwaysHaveATimeout() throws {
        let (sut, controller, _) = makeSUT(assertionTimeout: 600)

        try sut.reconcile(to: .awake(keepDisplayAwake: true))

        #expect(controller.creates.allSatisfy { $0.timeout == 600 })
    }

    @Test("Re-arming creates the replacement before releasing the old assertion")
    func rearmOverlapsSoThereIsNeverAnUnprotectedWindow() throws {
        let (sut, controller, clock) = makeSUT(assertionTimeout: 600, rearmInterval: 200)
        try sut.reconcile(to: .awake(keepDisplayAwake: false))
        let original = try #require(controller.creates.first?.id)
        controller.reset()

        clock.advance(by: 200)
        try sut.reconcile(to: .awake(keepDisplayAwake: false))

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

    @Test("Reconciling before the re-arm interval does not replace the assertion")
    func noChurnUntilRearmIsDue() throws {
        let (sut, controller, clock) = makeSUT(assertionTimeout: 600, rearmInterval: 200)
        try sut.reconcile(to: .awake(keepDisplayAwake: false))
        controller.reset()

        clock.advance(by: 199)
        try sut.reconcile(to: .awake(keepDisplayAwake: false))

        #expect(controller.events.isEmpty)
    }

    @Test("A stale assertion the OS already timed out is replaced, not trusted")
    func staleAssertionIsNotTrusted() throws {
        // If the app is blocked past the full timeout, powerd releases the assertion. Tracking
        // state alone must never be treated as proof that protection is still in place.
        let (sut, controller, clock) = makeSUT(assertionTimeout: 600, rearmInterval: 200)
        try sut.reconcile(to: .awake(keepDisplayAwake: false))
        let original = try #require(controller.creates.first?.id)
        controller.reset()

        clock.advance(by: 700)
        try sut.reconcile(to: .awake(keepDisplayAwake: false))

        #expect(controller.creates.count == 1)
        #expect(controller.creates.first?.id != original)
    }

    @Test(
        "Re-arm interval never exceeds a third of the timeout, leaving margin for a missed tick",
        arguments: [
            (600.0, TimeInterval?.none),
            (600.0, TimeInterval?.some(9_999)),
            (600.0, TimeInterval?.some(0)),
            (10.0, TimeInterval?.some(600)),
            (1.0, TimeInterval?.none),
            (.infinity, TimeInterval?.none),
            (600.0, TimeInterval?.some(.nan)),
            (600.0, TimeInterval?.some(.infinity)),
            (.nan, TimeInterval?.some(.nan)),
        ]
    )
    func rearmIntervalIsClamped(timeout: TimeInterval, requested: TimeInterval?) {
        let configuration = AssertionReconciler.Configuration(
            assertionTimeout: timeout,
            rearmInterval: requested,
            name: "Vigil test"
        )

        // Non-finite input must never leak into a value powerd is asked to honour.
        #expect(configuration.assertionTimeout.isFinite)
        #expect(configuration.rearmInterval.isFinite)
        #expect(configuration.rearmInterval > 0)
        #expect(configuration.rearmInterval * 3 <= configuration.assertionTimeout)
    }

    // MARK: - Release failures

    @Test("A failed release is retried rather than silently abandoned")
    func failedReleaseIsRetried() throws {
        let (sut, controller, _) = makeSUT()
        try sut.reconcile(to: .awake(keepDisplayAwake: false))
        controller.failNextRelease(with: PowerAssertionError(code: -1, operation: "test"))

        try sut.reconcile(to: .idle)

        #expect(sut.activeKinds.isEmpty)
        #expect(sut.retiringCount == 1)
        #expect(!controller.liveIDs.isEmpty)

        // The next reconcile retries and succeeds, so turning Vigil off really does turn it off.
        try sut.reconcile(to: .idle)

        #expect(sut.retiringCount == 0)
        #expect(controller.liveIDs.isEmpty)
    }

    @Test("A permanently unreleasable assertion is forgotten once its OS timeout has passed")
    func retirementIsBoundedByTheOSTimeout() throws {
        let (sut, controller, clock) = makeSUT(assertionTimeout: 600)
        try sut.reconcile(to: .awake(keepDisplayAwake: false))
        controller.alwaysFailRelease()
        try sut.reconcile(to: .idle)
        #expect(sut.retiringCount == 1)

        clock.advance(by: 601)
        try sut.reconcile(to: .idle)

        #expect(sut.retiringCount == 0)
    }
}
