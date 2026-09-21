import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Agent app: no Dock icon and no menu bar of its own. Also set via LSUIElement in Info.plist, but
// doing it here too means the app behaves correctly even when run directly from the build folder.
application.setActivationPolicy(.accessory)
application.run()
