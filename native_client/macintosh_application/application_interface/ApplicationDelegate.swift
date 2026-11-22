import AppKit

public final class ApplicationDelegate: NSObject, NSApplicationDelegate {
	let controller = ApplicationController(environment: .current())

	public func applicationDidFinishLaunching(_: Notification) {
		controller.launch()
	}

	public func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		controller.showMainWindow()
		return false
	}

	/// Terminating waits for the shutdown of both cores, so each coordinator finishes its batch and
	/// closes its database.
	public func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
		Task {
			await controller.terminate()
			application.reply(toApplicationShouldTerminate: true)
		}
		return .terminateLater
	}
}
