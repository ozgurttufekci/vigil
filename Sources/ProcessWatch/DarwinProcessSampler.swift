import Darwin
import Foundation

/// Reads process state through `libproc` and `sysctl`.
///
/// ## Why not `NSWorkspace`
///
/// `NSWorkspace.runningApplications` only returns Launch Services–registered applications. Measured
/// on a development Mac, it reported 0 of the 15 live `Code Helper` processes, so it cannot see the
/// helper and CLI processes this app exists to detect.
///
/// ## Privilege
///
/// `KERN_PROCARGS2` returns arguments only for processes owned by the same user (or to root). Other
/// users' processes fail with `EINVAL` and are skipped. No elevated privileges are used or needed.
public struct DarwinProcessSampler: ProcessSampling {
    public init() {}

    public func findProcesses(
        classifiedBy classify: @Sendable (String) -> String?
    ) -> [ProcessMatch] {
        var matches: [ProcessMatch] = []

        for pid in Self.allPIDs() {
            // Skip ourselves: our own command line could contain a rule pattern and self-match.
            guard pid != getpid() else { continue }
            guard let commandLine = Self.commandLine(for: pid) else { continue }
            guard let ruleID = classify(commandLine.joined(separator: " ")) else { continue }
            guard let startTime = Self.startTime(for: pid) else { continue }

            let name =
                commandLine.first.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "pid \(pid)"
            matches.append(
                ProcessMatch(
                    identity: ProcessIdentity(pid: pid, startTime: startTime, name: name),
                    ruleID: ruleID
                )
            )
        }

        return matches
    }

    public func sampleCPU(for identity: ProcessIdentity) -> CPUSample? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                proc_pid_rusage(identity.pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }

        // The PID may have been recycled since discovery. A different start time means this is a
        // different process, so the caller must not treat it as the one it was tracking.
        guard info.ri_proc_start_abstime == identity.startTime else { return nil }

        let nanoseconds = info.ri_user_time + info.ri_system_time
        return CPUSample(identity: identity, cpuTime: TimeInterval(nanoseconds) / 1_000_000_000)
    }

    // MARK: - Darwin plumbing

    private static func allPIDs() -> [Int32] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }

        // Ask for headroom: processes can appear between sizing the buffer and filling it.
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let byteCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard byteCount > 0 else { return [] }

        let returned = Int(byteCount) / MemoryLayout<Int32>.size
        return Array(pids[0..<min(returned, pids.count)]).filter { $0 > 0 }
    }

    private static func startTime(for pid: Int32) -> UInt64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? info.ri_proc_start_abstime : nil
    }

    /// Reads a process's full argument vector.
    ///
    /// The `KERN_PROCARGS2` buffer is laid out as: a 4-byte argument count, the executable path,
    /// zero or more padding NULs, then `argc` NUL-terminated argument strings.
    private static func commandLine(for pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        guard size > MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        guard argc > 0 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        let end = size

        func readCString() -> String? {
            guard cursor < end else { return nil }
            let start = cursor
            while cursor < end, buffer[cursor] != 0 { cursor += 1 }
            guard cursor <= end else { return nil }
            let string = String(decoding: buffer[start..<cursor], as: UTF8.self)
            cursor += 1
            return string
        }

        guard let executablePath = readCString() else { return nil }

        // Skip the NUL padding that aligns the start of the argument vector.
        while cursor < end, buffer[cursor] == 0 { cursor += 1 }

        var arguments: [String] = [executablePath]
        for _ in 0..<argc {
            guard let argument = readCString() else { break }
            arguments.append(argument)
        }
        return arguments
    }
}
