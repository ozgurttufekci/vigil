import Foundation

/// A pattern describing which processes should keep the Mac awake.
///
/// Rules are data rather than code so that presets can be shipped, edited, and updated without a
/// new build — important because the command lines of tools like Copilot change over time.
public struct ProcessRule: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    /// Shown in the UI. Must not contain command-line text.
    public let displayName: String
    /// Substrings; a process matches if its command line contains any of them.
    public let commandLinePatterns: [String]
    /// CPU percent at or above which the process counts as working. 100 means one full core.
    public let busyThreshold: Double
    /// CPU percent below which it counts as finished. Kept under `busyThreshold` so a process
    /// hovering near the line cannot flap the hold on and off.
    public let idleThreshold: Double
    /// How long the process must stay quiet before the hold is released.
    ///
    /// Agents routinely pause between turns — waiting on a model response or on the user. Releasing
    /// immediately would let the Mac sleep in exactly those gaps.
    public let gracePeriod: TimeInterval
    public let isEnabled: Bool

    public init(
        id: String,
        displayName: String,
        commandLinePatterns: [String],
        busyThreshold: Double = 40,
        idleThreshold: Double = 10,
        gracePeriod: TimeInterval = 180,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.commandLinePatterns = commandLinePatterns
        self.busyThreshold = max(busyThreshold, 0)
        // Enforce the hysteresis gap even if a caller supplies inverted thresholds.
        self.idleThreshold = min(max(idleThreshold, 0), max(busyThreshold, 0))
        self.gracePeriod = max(gracePeriod, 0)
        self.isEnabled = isEnabled
    }

    public func matches(commandLine: String) -> Bool {
        commandLinePatterns.contains { !$0.isEmpty && commandLine.contains($0) }
    }
}

extension ProcessRule {
    /// The rules shipped by default.
    ///
    /// Copilot runs in two very different shapes, and both need covering: an embedded helper spawned
    /// by VS Code, and a standalone CLI.
    public static let presets: [ProcessRule] = [
        ProcessRule(
            id: "github-copilot",
            displayName: "GitHub Copilot",
            commandLinePatterns: ["@github/copilot"]
        ),
        ProcessRule(
            id: "claude-code",
            displayName: "Claude Code",
            commandLinePatterns: ["@anthropic-ai/claude-code"]
        ),
        ProcessRule(
            id: "container-build",
            displayName: "Container build",
            commandLinePatterns: ["docker build", "docker-buildx", "podman build"],
            busyThreshold: 50,
            idleThreshold: 15,
            gracePeriod: 60
        ),
        ProcessRule(
            id: "media-encode",
            displayName: "Media encoding",
            commandLinePatterns: ["ffmpeg", "HandBrakeCLI"],
            busyThreshold: 50,
            idleThreshold: 15,
            gracePeriod: 30,
            isEnabled: false
        ),
    ]
}
