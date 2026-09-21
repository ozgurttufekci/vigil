import Foundation

/// A process we are tracking, identified in a way that survives PID reuse.
///
/// PIDs are recycled. `startTime` distinguishes "the process we have been sampling" from "a new
/// process that happens to have inherited its PID", which would otherwise produce nonsense CPU
/// deltas and could keep the Mac awake for an unrelated program.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    /// Mach absolute time at which the process started.
    public let startTime: UInt64
    /// The executable's file name, safe to display.
    public let name: String

    public init(pid: Int32, startTime: UInt64, name: String) {
        self.pid = pid
        self.startTime = startTime
        self.name = name
    }
}

/// A CPU usage reading for one process.
public struct CPUSample: Sendable {
    public let identity: ProcessIdentity
    /// Cumulative user + system CPU time consumed since the process started.
    public let cpuTime: TimeInterval

    public init(identity: ProcessIdentity, cpuTime: TimeInterval) {
        self.identity = identity
        self.cpuTime = cpuTime
    }
}

/// A process that matched a rule, paired with the rule that matched it.
public struct ProcessMatch: Sendable, Hashable {
    public let identity: ProcessIdentity
    public let ruleID: String

    public init(identity: ProcessIdentity, ruleID: String) {
        self.identity = identity
        self.ruleID = ruleID
    }
}

/// Reads process information from the system.
///
/// Abstracted so the detection engine can be tested deterministically without spawning processes.
public protocol ProcessSampling: Sendable {
    /// Returns every process owned by the current user that `classify` accepts.
    ///
    /// `classify` is handed the raw command line and returns the ID of the rule that matched, or
    /// `nil`. Command lines routinely contain API keys and access tokens, so that string is never
    /// returned, stored, or logged — only the identity and the matched rule ID escape this call.
    /// Attribution has to happen here, inside the closure, precisely because the arguments are gone
    /// by the time the call returns.
    func findProcesses(classifiedBy classify: @Sendable (String) -> String?) -> [ProcessMatch]

    /// Reads cumulative CPU time for a process, or `nil` if it has exited.
    func sampleCPU(for identity: ProcessIdentity) -> CPUSample?
}
