import Foundation
import OSLog
import UserNotifications

enum Log {
    private static let logger = Logger(subsystem: "dev.vigil.app", category: "vigil")

    /// Logs an error.
    ///
    /// Anything passed here must already be free of command-line text: process arguments routinely
    /// contain API keys, and the unified log is readable by other tools on the machine.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}

@MainActor
enum Notifier {
    private static var isAuthorized = false

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { granted, _ in
                Task { @MainActor in isAuthorized = granted }
            }
    }

    static func holdExpired() {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Vigil stopped"
        content.body = "Your Mac can sleep normally again."
        UNUserNotificationCenter.current()
            .add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
    }
}
