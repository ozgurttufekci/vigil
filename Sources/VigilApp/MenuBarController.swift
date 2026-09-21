import AppKit
import ProcessWatch

/// Builds and drives the status bar item.
///
/// Uses `NSStatusItem` rather than SwiftUI's `MenuBarExtra`, which offers no way to distinguish a
/// left click from a right click and, in `.menu` style, blocks the run loop while the menu is open
/// (which would freeze a live countdown).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: VigilController
    private let settings: Settings
    private let menu = NSMenu()

    private enum Duration {
        static let options: [(title: String, seconds: TimeInterval?)] = [
            ("15 minutes", 15 * 60),
            ("30 minutes", 30 * 60),
            ("1 hour", 60 * 60),
            ("2 hours", 2 * 60 * 60),
            ("Until I stop it", nil),
        ]
    }

    init(controller: VigilController, settings: Settings) {
        self.controller = controller
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = Self.icon(active: false)
            button.image?.isTemplate = true
        }
        render()
    }

    // MARK: - Rendering

    func render() {
        let status = controller.status

        if let button = statusItem.button {
            button.image = Self.icon(active: status.isAwake)
            button.image?.isTemplate = true

            if settings.showCountdown, let remaining = status.remaining {
                button.title = " \(VigilController.format(duration: remaining))"
            } else {
                button.title = ""
            }
            button.toolTip = Self.tooltip(for: status)
            // The image alone conveys state, so VoiceOver needs it spelled out.
            button.setAccessibilityLabel(Self.accessibilityLabel(for: status))
        }
    }

    private static func icon(active: Bool) -> NSImage? {
        let name = active ? "eye.fill" : "eye"
        let description = active ? "Vigil is keeping your Mac awake" : "Vigil is idle"
        return NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private static func tooltip(for status: VigilStatus) -> String {
        guard status.isAwake else { return "Vigil — your Mac can sleep normally" }
        if let detection = status.detections.first {
            return "Vigil — \(detection.ruleName) is working"
        }
        if let remaining = status.remaining {
            return "Vigil — awake for another \(VigilController.format(duration: remaining))"
        }
        return "Vigil — keeping your Mac awake"
    }

    private static func accessibilityLabel(for status: VigilStatus) -> String {
        status.isAwake ? "Vigil, keeping your Mac awake" : "Vigil, your Mac can sleep"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = controller.status

        menu.addItem(statusHeader(for: status))

        for detection in status.detections {
            // Shows the rule and process name only; command lines never reach the UI.
            let cpu = String(format: "%.0f%% CPU", detection.cpuPercent)
            let suffix = detection.isCoolingDown ? " — finishing up" : ""
            let item = NSMenuItem(
                title: "   \(detection.ruleName) · \(detection.processName) · \(cpu)\(suffix)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        if status.batteryBlocked {
            let item = NSMenuItem(
                title: "   Paused — battery is low",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if controller.isManuallyActive {
            menu.addItem(
                item(title: "Stop keeping awake", action: #selector(stopManual))
            )
            menu.addItem(item(title: "Add 30 minutes", action: #selector(extendThirty)))
        } else {
            let header = NSMenuItem(title: "Keep awake for…", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, option) in Duration.options.enumerated() {
                let entry = item(title: "   \(option.title)", action: #selector(startManual(_:)))
                entry.tag = index
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())

        let auto = item(title: "Detect work automatically", action: #selector(toggleAutoDetect))
        auto.state = settings.autoDetectEnabled ? .on : .off
        menu.addItem(auto)

        if settings.autoDetectEnabled {
            let submenu = NSMenu()
            for rule in ProcessRule.presets {
                let entry = item(title: rule.displayName, action: #selector(toggleRule(_:)))
                entry.state = settings.isRuleEnabled(rule) ? .on : .off
                entry.representedObject = rule.id
                submenu.addItem(entry)
            }
            let watching = NSMenuItem(title: "   Watching", action: nil, keyEquivalent: "")
            menu.addItem(watching)
            menu.setSubmenu(submenu, for: watching)
        }

        let display = item(title: "Keep display awake too", action: #selector(toggleDisplay))
        display.state = settings.keepDisplayAwake ? .on : .off
        display.toolTip = "Uses noticeably more battery. Background work runs fine without it."
        menu.addItem(display)

        let onAC = item(title: "Auto-detect only on power adapter", action: #selector(togglePauseOnBattery))
        onAC.state = settings.pauseOnBattery ? .on : .off
        menu.addItem(onAC)

        let countdown = item(title: "Show countdown in menu bar", action: #selector(toggleCountdown))
        countdown.state = settings.showCountdown ? .on : .off
        menu.addItem(countdown)

        menu.addItem(.separator())
        menu.addItem(item(title: "Quit Vigil", action: #selector(quit), key: "q"))
    }

    private func statusHeader(for status: VigilStatus) -> NSMenuItem {
        let title: String
        if !status.isAwake {
            title = "Your Mac can sleep normally"
        } else if !status.detections.isEmpty {
            title = "Awake — work in progress"
        } else if let remaining = status.remaining {
            title = "Awake for another \(VigilController.format(duration: remaining))"
        } else {
            title = "Awake until you stop it"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func startManual(_ sender: NSMenuItem) {
        guard Duration.options.indices.contains(sender.tag) else { return }
        controller.startManualHold(duration: Duration.options[sender.tag].seconds)
    }

    @objc private func stopManual() {
        controller.stopManualHold()
    }

    @objc private func extendThirty() {
        controller.extendManualHold(by: 30 * 60)
    }

    @objc private func toggleAutoDetect() {
        settings.autoDetectEnabled.toggle()
        controller.reloadRules()
        controller.refresh()
    }

    @objc private func toggleRule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let rule = ProcessRule.presets.first(where: { $0.id == id })
        else { return }
        settings.setRule(rule, enabled: !settings.isRuleEnabled(rule))
        controller.reloadRules()
        controller.refresh()
    }

    @objc private func toggleDisplay() {
        settings.keepDisplayAwake.toggle()
        controller.refresh()
    }

    @objc private func togglePauseOnBattery() {
        settings.pauseOnBattery.toggle()
        controller.refresh()
    }

    @objc private func toggleCountdown() {
        settings.showCountdown.toggle()
        render()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
