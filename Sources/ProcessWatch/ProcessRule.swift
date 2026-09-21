import Foundation

/// How to tell whether a matched process is actually working.
///
/// One signal does not fit every workload, and picking the wrong one silently breaks detection.
public enum ActivitySignal: Sendable, Hashable, Codable {
    /// Busy while the process burns CPU.
    ///
    /// Right for compilers, encoders, and container builds, which are CPU-bound.
    case cpu(busyThreshold: Double, idleThreshold: Double)

    /// Busy while files under these paths are changing. `~` is expanded.
    ///
    /// Right for AI coding agents. Measured on a live Copilot session, the agent process used
    /// 0.03–0.09% CPU while actively working, because it spends nearly all its time waiting on
    /// model responses; the real work happens on remote servers and in processes that are not even
    /// its descendants. Neither its own CPU nor its process tree's CPU is a usable signal. Its
    /// session log, by contrast, grows at every turn boundary.
    ///
    /// The signal is bursty: nothing is written while a single long tool call runs. That is what
    /// the rule's grace period is for, and why agent rules use a much longer one than CPU rules.
    case fileActivity(paths: [String])

    public static let defaultCPU = ActivitySignal.cpu(busyThreshold: 40, idleThreshold: 10)
}

/// A pattern describing which processes should keep the Mac awake, and how to tell when they are
/// working.
///
/// Rules are data rather than code so presets can be shipped, edited, and updated without a new
/// build — important because the command lines of tools like Copilot change over time.
public struct ProcessRule: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    /// Shown in the UI. Must not contain command-line text.
    public let displayName: String
    /// Substrings; a process matches if its command line contains any of them.
    ///
    /// A matching process must exist for the rule to hold the Mac awake, even for a file-activity
    /// rule. Without that requirement, a leftover log file touched by something else could pin the
    /// Mac awake while the tool is not even running.
    public let commandLinePatterns: [String]
    public let signal: ActivitySignal
    /// How long the rule must stay quiet before the hold is released.
    ///
    /// Agents routinely pause between turns — waiting on a model response or on the user. Releasing
    /// immediately would let the Mac sleep in exactly those gaps.
    public let gracePeriod: TimeInterval
    public let isEnabled: Bool

    public init(
        id: String,
        displayName: String,
        commandLinePatterns: [String],
        signal: ActivitySignal = .defaultCPU,
        gracePeriod: TimeInterval = 180,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.commandLinePatterns = commandLinePatterns
        self.signal = Self.sanitize(signal)
        self.gracePeriod = max(gracePeriod, 0)
        self.isEnabled = isEnabled
    }

    /// Enforces the hysteresis gap even if a caller supplies inverted thresholds, so a process
    /// sitting near the line cannot flap the Mac's power state.
    private static func sanitize(_ signal: ActivitySignal) -> ActivitySignal {
        guard case .cpu(let busy, let idle) = signal else { return signal }
        let safeBusy = max(busy, 0)
        return .cpu(busyThreshold: safeBusy, idleThreshold: min(max(idle, 0), safeBusy))
    }

    public func matches(commandLine: String) -> Bool {
        commandLinePatterns.contains { !$0.isEmpty && commandLine.contains($0) }
    }

    /// Paths this rule needs watched, if any.
    public var watchedPaths: [String] {
        if case .fileActivity(let paths) = signal { return paths }
        return []
    }
}

extension ProcessRule {
    /// The rules shipped by default.
    ///
    /// Copilot runs in two very different shapes and both need covering: an embedded helper spawned
    /// by VS Code, and a standalone CLI. Both are detected by file activity rather than CPU.
    public static let presets: [ProcessRule] = [
        ProcessRule(
            id: "github-copilot",
            displayName: "GitHub Copilot",
            commandLinePatterns: ["@github/copilot"],
            // The parent directory, so both the per-session logs and the shared session store are
            // covered. Writes pause for the length of a tool call, hence the long grace period.
            signal: .fileActivity(paths: ["~/.copilot"]),
            gracePeriod: 300
        ),
        ProcessRule(
            id: "claude-code",
            displayName: "Claude Code",
            commandLinePatterns: ["@anthropic-ai/claude-code"],
            signal: .fileActivity(paths: ["~/.claude"]),
            gracePeriod: 300
        ),
        ProcessRule(
            id: "container-build",
            displayName: "Container build",
            commandLinePatterns: ["docker build", "docker-buildx", "podman build"],
            signal: .cpu(busyThreshold: 50, idleThreshold: 15),
            gracePeriod: 60
        ),
        ProcessRule(
            id: "compiler",
            displayName: "Compiler or build",
            commandLinePatterns: ["xcodebuild", "swift-frontend", "cargo build"],
            signal: .cpu(busyThreshold: 50, idleThreshold: 15),
            gracePeriod: 60,
            isEnabled: false
        ),
        ProcessRule(
            id: "media-encode",
            displayName: "Media encoding",
            commandLinePatterns: ["ffmpeg", "HandBrakeCLI"],
            signal: .cpu(busyThreshold: 50, idleThreshold: 15),
            gracePeriod: 30,
            isEnabled: false
        ),
    ]
}
