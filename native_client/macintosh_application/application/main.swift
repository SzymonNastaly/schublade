import AppKit
import ApplicationInterface

let application = NSApplication.shared
#if DEBUG
let delegate = ApplicationDelegate()
#else
let softwareUpdate = SparkleSoftwareUpdate()
let delegate = ApplicationDelegate(softwareUpdate: softwareUpdate)
softwareUpdate.applicationDelegate = delegate
softwareUpdate.start()
#endif
application.delegate = delegate
application.run()
