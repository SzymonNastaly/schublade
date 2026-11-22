import AppKit
import ApplicationInterface

let application = NSApplication.shared
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
