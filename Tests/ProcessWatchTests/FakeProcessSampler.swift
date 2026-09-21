import Foundation
import ProcessWatch

/// A scriptable stand-in for the real process table.
///
/// Also records the command lines it was asked to classify, so tests can assert that the engine
/// never gets to keep them.
final class FakeProcessSampler: ProcessSampling, @unchecked Sendable {
    struct FakeProcess {
        var identity: ProcessIdentity
        var commandLine: String
        /// Cumulative CPU seconds; tests advance this to simulate load.
        var cpuTime: TimeInterval
        var hasExited: Bool = false
    }

    private let lock = NSLock()
    private var _processes: [Int32: FakeProcess] = [:]
    private var _classifiedCommandLines: [String] = []
    private var _sweepCount = 0

    var sweepCount: Int { lock.withLock { _sweepCount } }
    var classifiedCommandLines: [String] { lock.withLock { _classifiedCommandLines } }

    func add(
        pid: Int32,
        name: String,
        commandLine: String,
        startTime: UInt64 = 1,
        cpuTime: TimeInterval = 0
    ) {
        lock.withLock {
            _processes[pid] = FakeProcess(
                identity: ProcessIdentity(pid: pid, startTime: startTime, name: name),
                commandLine: commandLine,
                cpuTime: cpuTime
            )
        }
    }

    /// Simulates the process consuming CPU seconds.
    func burnCPU(pid: Int32, seconds: TimeInterval) {
        lock.withLock { _processes[pid]?.cpuTime += seconds }
    }

    func exit(pid: Int32) {
        lock.withLock { _processes[pid]?.hasExited = true }
    }

    /// Simulates PID reuse: same PID, different process.
    func replace(pid: Int32, name: String, commandLine: String, startTime: UInt64) {
        lock.withLock {
            _processes[pid] = FakeProcess(
                identity: ProcessIdentity(pid: pid, startTime: startTime, name: name),
                commandLine: commandLine,
                cpuTime: 0
            )
        }
    }

    func findProcesses(classifiedBy classify: @Sendable (String) -> String?) -> [ProcessMatch] {
        let snapshot = lock.withLock {
            _sweepCount += 1
            return _processes.values.filter { !$0.hasExited }
        }

        var matches: [ProcessMatch] = []
        for process in snapshot {
            lock.withLock { _classifiedCommandLines.append(process.commandLine) }
            if let ruleID = classify(process.commandLine) {
                matches.append(ProcessMatch(identity: process.identity, ruleID: ruleID))
            }
        }
        return matches
    }

    func sampleCPU(for identity: ProcessIdentity) -> CPUSample? {
        lock.withLock {
            guard let process = _processes[identity.pid], !process.hasExited else { return nil }
            // Mirrors the real sampler: a different start time means the PID was recycled.
            guard process.identity.startTime == identity.startTime else { return nil }
            return CPUSample(identity: identity, cpuTime: process.cpuTime)
        }
    }
}
