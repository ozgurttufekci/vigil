import Foundation
import ProcessWatch
import TestSupport
import Testing

@Suite("AutoDetectEngine")
struct AutoDetectEngineTests {
    private let copilot = ProcessRule(
        id: "github-copilot",
        displayName: "GitHub Copilot",
        commandLinePatterns: ["@github/copilot"],
        busyThreshold: 40,
        idleThreshold: 10,
        gracePeriod: 180
    )

    private func makeSUT(
        rules: [ProcessRule]? = nil,
        samplingInterval: TimeInterval = 5,
        discoveryInterval: TimeInterval = 30
    ) -> (AutoDetectEngine, FakeProcessSampler, ManualClock) {
        let clock = ManualClock()
        let sampler = FakeProcessSampler()
        let engine = AutoDetectEngine(
            sampler: sampler,
            clock: clock,
            rules: rules ?? [copilot],
            configuration: .init(
                discoveryInterval: discoveryInterval,
                samplingInterval: samplingInterval
            )
        )
        return (engine, sampler, clock)
    }

    /// Drives the engine for `duration`, with the process consuming `cpuRatio` cores throughout.
    private func run(
        _ engine: AutoDetectEngine,
        _ sampler: FakeProcessSampler,
        _ clock: ManualClock,
        pid: Int32,
        cpuRatio: Double,
        duration: TimeInterval,
        step: TimeInterval = 5
    ) {
        var elapsed: TimeInterval = 0
        while elapsed < duration {
            clock.advance(by: step)
            sampler.burnCPU(pid: pid, seconds: step * cpuRatio)
            engine.refresh()
            elapsed += step
        }
    }

    // MARK: - Core behaviour

    @Test("A busy matching process keeps the Mac awake")
    func busyProcessKeepsAwake() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")

        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 1.2, duration: 15)

        #expect(engine.shouldKeepAwake)
        #expect(engine.activeDetections.first?.ruleName == "GitHub Copilot")
    }

    @Test("A resident but idle process does NOT keep the Mac awake")
    func idleProcessDoesNotKeepAwake() {
        // The decisive case. A Copilot helper stays resident for the whole editor session; holding
        // the Mac awake merely because it exists would be worse than not running this app at all.
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")

        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 0.0, duration: 60)

        #expect(!engine.shouldKeepAwake)
        #expect(engine.activeDetections.isEmpty)
    }

    @Test("A non-matching busy process is ignored")
    func nonMatchingProcessIgnored() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "chrome", commandLine: "/Applications/Chrome --renderer")

        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 3.0, duration: 30)

        #expect(!engine.shouldKeepAwake)
    }

    // MARK: - Hysteresis

    @Test("A brief pause between turns does not drop the hold")
    func gracePeriodSurvivesPauseBetweenTurns() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")
        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)
        #expect(engine.shouldKeepAwake)

        // Agent goes quiet for two minutes waiting on a model response.
        run(engine, sampler, clock, pid: 100, cpuRatio: 0.0, duration: 120)

        #expect(engine.shouldKeepAwake)
        #expect(engine.activeDetections.first?.isCoolingDown == true)
    }

    @Test("Work resuming during the grace period restores the busy state")
    func resumingWorkCancelsCooldown() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")
        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)
        run(engine, sampler, clock, pid: 100, cpuRatio: 0.0, duration: 60)
        #expect(engine.activeDetections.first?.isCoolingDown == true)

        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)

        #expect(engine.shouldKeepAwake)
        #expect(engine.activeDetections.first?.isCoolingDown == false)
    }

    @Test("Staying quiet past the grace period releases the hold")
    func holdReleasesAfterGracePeriod() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")
        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)
        #expect(engine.shouldKeepAwake)

        run(engine, sampler, clock, pid: 100, cpuRatio: 0.0, duration: 200)

        #expect(!engine.shouldKeepAwake)
    }

    @Test("CPU hovering between the thresholds cannot flap the hold")
    func hysteresisPreventsFlapping() {
        // Between idleThreshold (10%) and busyThreshold (40%) the state must not change, so a
        // process sitting at 25% never rapidly toggles the Mac's power state.
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")
        engine.refresh()

        run(engine, sampler, clock, pid: 100, cpuRatio: 0.25, duration: 60)

        #expect(!engine.shouldKeepAwake)

        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)
        #expect(engine.shouldKeepAwake)

        // Falling back to the same middling load must not drop it either.
        run(engine, sampler, clock, pid: 100, cpuRatio: 0.25, duration: 60)
        #expect(engine.shouldKeepAwake)
    }

    // MARK: - Lifecycle

    @Test("A process exiting releases the hold immediately")
    func exitReleasesHold() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")
        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)
        #expect(engine.shouldKeepAwake)

        sampler.exit(pid: 100)
        clock.advance(by: 5)
        engine.refresh()

        // No grace period for a dead process: there is nothing left to wait for.
        #expect(!engine.shouldKeepAwake)
    }

    @Test("A recycled PID is not mistaken for the process being tracked")
    func pidReuseIsDetected() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(
            pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio", startTime: 1
        )
        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)
        #expect(engine.shouldKeepAwake)

        // The OS hands PID 100 to something entirely unrelated.
        sampler.replace(pid: 100, name: "bash", commandLine: "/bin/bash", startTime: 999)
        clock.advance(by: 5)
        engine.refresh()

        #expect(!engine.shouldKeepAwake)
    }

    @Test("Several matching processes are tracked independently")
    func multipleProcessesTrackedIndependently() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")
        sampler.add(pid: 200, name: "copilot", commandLine: "/opt/homebrew/bin/@github/copilot")
        engine.refresh()

        var elapsed: TimeInterval = 0
        while elapsed < 20 {
            clock.advance(by: 5)
            sampler.burnCPU(pid: 100, seconds: 5 * 1.5)
            sampler.burnCPU(pid: 200, seconds: 0)
            engine.refresh()
            elapsed += 5
        }

        #expect(engine.activeDetections.count == 1)
        #expect(engine.activeDetections.first?.pid == 100)
        #expect(engine.shouldKeepAwake)
    }

    // MARK: - Rules

    @Test("A disabled rule matches nothing")
    func disabledRuleIsInert() {
        let disabled = ProcessRule(
            id: "github-copilot",
            displayName: "GitHub Copilot",
            commandLinePatterns: ["@github/copilot"],
            isEnabled: false
        )
        let (engine, sampler, clock) = makeSUT(rules: [disabled])
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")

        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 2.0, duration: 30)

        #expect(!engine.shouldKeepAwake)
    }

    @Test("Detections are attributed to the rule that actually matched")
    func detectionsCarryTheMatchingRule() {
        let rules = [
            copilot,
            ProcessRule(
                id: "media-encode",
                displayName: "Media encoding",
                commandLinePatterns: ["ffmpeg"]
            ),
        ]
        let (engine, sampler, clock) = makeSUT(rules: rules)
        sampler.add(pid: 200, name: "ffmpeg", commandLine: "/usr/bin/ffmpeg -i in.mov out.mp4")

        engine.refresh()
        run(engine, sampler, clock, pid: 200, cpuRatio: 2.0, duration: 20)

        #expect(engine.activeDetections.first?.ruleID == "media-encode")
        #expect(engine.activeDetections.first?.ruleName == "Media encoding")
    }

    @Test("Inverted thresholds are corrected rather than trusted")
    func invertedThresholdsAreClamped() {
        let rule = ProcessRule(
            id: "x", displayName: "X", commandLinePatterns: ["x"],
            busyThreshold: 10, idleThreshold: 90
        )

        #expect(rule.idleThreshold <= rule.busyThreshold)
    }

    // MARK: - Cost and privacy

    @Test("Discovery is throttled; CPU sampling is not")
    func discoverySelfThrottles() {
        // Sweeping every process reads argv for hundreds of PIDs and is far too expensive to run on
        // the sampling interval.
        let (engine, sampler, clock) = makeSUT(samplingInterval: 5, discoveryInterval: 30)
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")

        engine.refresh()
        for _ in 0..<6 {
            clock.advance(by: 5)
            engine.refresh()
        }

        // 30 seconds elapsed: the initial sweep plus exactly one more, not one per refresh.
        #expect(sampler.sweepCount == 2)
    }

    @Test("Command lines are classified but never surfaced in detections")
    func commandLinesNeverEscape() {
        // Command lines routinely contain API keys. They must be matched inside the sampler and
        // discarded there, never reaching anything the UI can render or a log can capture.
        let secret = "node @github/copilot --token=sk-SUPERSECRET-DO-NOT-LEAK"
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: secret)

        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)

        #expect(sampler.classifiedCommandLines.contains(secret))

        let detection = engine.activeDetections.first
        #expect(detection != nil)
        let rendered = "\(detection!)"
        #expect(!rendered.contains("SUPERSECRET"))
        #expect(!rendered.contains("--token"))
        #expect(detection?.processName == "Code Helper")
    }

    @Test("Resetting forgets every tracked process")
    func resetClearsState() {
        let (engine, sampler, clock) = makeSUT()
        sampler.add(pid: 100, name: "Code Helper", commandLine: "node @github/copilot --stdio")
        engine.refresh()
        run(engine, sampler, clock, pid: 100, cpuRatio: 1.5, duration: 20)
        #expect(engine.shouldKeepAwake)

        engine.reset()

        #expect(!engine.shouldKeepAwake)
        #expect(engine.activeDetections.isEmpty)
    }
}

@Suite("ProcessRule presets")
struct ProcessRulePresetTests {
    @Test("Ship a Copilot preset that matches the real VS Code helper command line")
    func copilotPresetMatchesRealCommandLine() {
        // Captured from a live process on macOS 26: a Code Helper child of VS Code.
        let real =
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/"
            + "MacOS/Code Helper /Applications/Visual Studio Code.app/Contents/Resources/app/"
            + "node_modules.asar.unpacked/@github/copilot-darwin-arm64/index.js --headless --stdio"
        let rule = try! #require(ProcessRule.presets.first { $0.id == "github-copilot" })

        #expect(rule.matches(commandLine: real))
    }

    @Test("Presets use hysteresis and are enabled sensibly")
    func presetsAreSane() {
        for rule in ProcessRule.presets {
            #expect(rule.idleThreshold < rule.busyThreshold, "\(rule.id) needs a hysteresis gap")
            #expect(rule.gracePeriod > 0, "\(rule.id) needs a grace period")
            #expect(!rule.commandLinePatterns.isEmpty)
        }
        #expect(ProcessRule.presets.contains { $0.id == "github-copilot" && $0.isEnabled })
    }

    @Test("Presets do not match an unrelated command line")
    func presetsDoNotFalsePositive() {
        let unrelated = "/Applications/Safari.app/Contents/MacOS/Safari"
        for rule in ProcessRule.presets {
            #expect(!rule.matches(commandLine: unrelated), "\(rule.id) false-positived")
        }
    }
}
