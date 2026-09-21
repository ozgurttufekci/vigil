import Foundation
import MonotonicTime
import Testing

@Suite("SystemMonotonicClock")
struct MonotonicClockTests {
    @Test("Advances monotonically")
    func advancesMonotonically() {
        let clock = SystemMonotonicClock()

        let first = clock.now
        Thread.sleep(forTimeInterval: 0.05)
        let second = clock.now

        #expect(second > first)
        #expect(second - first >= 0.04)
    }

    @Test("Keeps counting across machine sleep, unlike systemUptime")
    func countsTimeSpentAsleep() {
        // `ProcessInfo.systemUptime` stops while the Mac is asleep. If holds were measured against
        // it, a 30-minute hold started before an overnight suspend would still have time left the
        // next morning and would refuse to let the Mac sleep again. The clock must therefore be at
        // least as large, and on any machine that has ever slept it will be strictly larger.
        let clock = SystemMonotonicClock()

        #expect(clock.now >= ProcessInfo.processInfo.systemUptime)
    }

    @Test("Reports a finite, positive value")
    func isFiniteAndPositive() {
        let now = SystemMonotonicClock().now

        #expect(now.isFinite)
        #expect(now > 0)
    }
}
