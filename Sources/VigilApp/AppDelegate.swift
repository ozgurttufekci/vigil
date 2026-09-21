import AppKit
import KeepAwakeCore
import MonotonicTime
import PowerAssertions
import ProcessWatch

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var controller: VigilController?
    private var timer: Timer?

    /// How often the controller re-samples and re-arms.
    ///
    /// Also the resolution of the menu bar countdown, so it stays cheap while looking live.
    private let tickInterval: TimeInterval = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        let clock = SystemMonotonicClock()
        let settings = Settings()

        let reconciler = AssertionReconciler(
            controller: IOKitPowerAssertionController(),
            clock: clock,
            configuration: .init(name: "Vigil")
        )
        let coordinator = KeepAwakeCoordinator(reconciler: reconciler, clock: clock)
        let detector = AutoDetectEngine(
            sampler: DarwinProcessSampler(),
            clock: clock,
            rules: settings.effectiveRules
        )
        let controller = VigilController(
            coordinator: coordinator,
            detector: detector,
            powerReader: IOKitPowerStateReader(),
            settings: settings,
            clock: clock
        )
        self.controller = controller

        let menuBar = MenuBarController(controller: controller, settings: settings)
        self.menuBar = menuBar
        controller.onChange = { [weak menuBar] in menuBar?.render() }

        Notifier.requestAuthorization()
        startTimer()
        controller.refresh()
        Log.info("Vigil started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        // Release assertions explicitly rather than relying on the OS timeout, so the Mac can sleep
        // the moment the user quits.
        controller?.shutdown()
        Log.info("Vigil stopped")
    }

    private func startTimer() {
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.refresh() }
        }
        // Common mode keeps the countdown and, more importantly, the watchdog re-arm running while
        // a menu is open or a window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
