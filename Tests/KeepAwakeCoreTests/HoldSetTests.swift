import Foundation
import KeepAwakeCore
import Testing

@Suite("HoldSet")
struct HoldSetTests {
    private func hold(
        reason: String = "test",
        expiry: TimeInterval?,
        keepDisplayAwake: Bool = false,
        createdAt: TimeInterval = 1000
    ) -> Hold {
        Hold(
            source: .manual,
            reason: reason,
            expiry: expiry,
            keepDisplayAwake: keepDisplayAwake,
            createdAt: createdAt
        )
    }

    @Test("An empty set wants nothing")
    func emptySetIsIdle() {
        #expect(HoldSet().desiredState(at: 1000) == .idle)
    }

    @Test("A live hold keeps the Mac awake")
    func liveHoldIsAwake() {
        var set = HoldSet()
        set.insert(hold(expiry: 2000))

        #expect(set.desiredState(at: 1500) == .awake(keepDisplayAwake: false))
    }

    @Test("A hold expires exactly at its deadline, not after")
    func expiryIsInclusive() {
        var set = HoldSet()
        set.insert(hold(expiry: 2000))

        #expect(set.desiredState(at: 1999) == .awake(keepDisplayAwake: false))
        #expect(set.desiredState(at: 2000) == .idle)
    }

    @Test("An indefinite hold never expires on its own")
    func indefiniteHoldNeverExpires() {
        var set = HoldSet()
        set.insert(hold(expiry: nil))

        #expect(set.desiredState(at: .greatestFiniteMagnitude) == .awake(keepDisplayAwake: false))
    }

    @Test("Holds stack: the Mac stays awake until the last one expires")
    func holdsStack() {
        var set = HoldSet()
        set.insert(hold(reason: "short", expiry: 1500))
        set.insert(hold(reason: "long", expiry: 3000))

        #expect(set.desiredState(at: 2000) == .awake(keepDisplayAwake: false))
        #expect(set.desiredState(at: 3000) == .idle)
    }

    @Test("One display-awake hold upgrades the whole set")
    func anyDisplayHoldUpgradesState() {
        var set = HoldSet()
        set.insert(hold(reason: "system", expiry: 3000, keepDisplayAwake: false))
        set.insert(hold(reason: "display", expiry: 2000, keepDisplayAwake: true))

        #expect(set.desiredState(at: 1500) == .awake(keepDisplayAwake: true))
    }

    @Test("When the display hold expires the set downgrades instead of dropping protection")
    func expiringDisplayHoldDowngrades() {
        var set = HoldSet()
        set.insert(hold(reason: "system", expiry: 3000, keepDisplayAwake: false))
        set.insert(hold(reason: "display", expiry: 2000, keepDisplayAwake: true))

        #expect(set.desiredState(at: 2500) == .awake(keepDisplayAwake: false))
    }

    @Test("Pruning returns the expired holds and leaves the live ones")
    func pruneReturnsExpired() {
        var set = HoldSet()
        set.insert(hold(reason: "gone", expiry: 1500))
        set.insert(hold(reason: "stays", expiry: 3000))

        let expired = set.pruneExpired(at: 2000)

        #expect(expired.map(\.reason) == ["gone"])
        #expect(set.count == 1)
        #expect(set.all.map(\.reason) == ["stays"])
    }

    @Test("The soonest deadline drives the next wake-up")
    func nextExpiryIsTheSoonest() {
        var set = HoldSet()
        set.insert(hold(expiry: 3000))
        set.insert(hold(expiry: 1800))
        set.insert(hold(expiry: nil))

        #expect(set.nextExpiry(at: 1000) == 1800)
    }

    @Test("Indefinite-only sets schedule no wake-up")
    func nextExpiryIsNilWhenAllIndefinite() {
        var set = HoldSet()
        set.insert(hold(expiry: nil))

        #expect(set.nextExpiry(at: 1000) == nil)
    }

    @Test("Remaining time is clamped at zero and nil for indefinite holds")
    func remainingTime() {
        #expect(hold(expiry: 2000).remaining(at: 1500) == 500)
        #expect(hold(expiry: 2000).remaining(at: 2500) == 0)
        #expect(hold(expiry: nil).remaining(at: 1500) == nil)
    }
}
