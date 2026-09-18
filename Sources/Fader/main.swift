import AppKit

// A menu bar app: no dock icon, no main window, no Cmd-Tab entry. The whole
// product lives in the status item.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
