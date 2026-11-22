import AppKit

public final class ApplicationDelegate: NSObject, NSApplicationDelegate {
	let controller = ApplicationController(environment: .current())

	public func applicationDidFinishLaunching(_: Notification) {
		controller.launch()
	}

	/// Terminating waits for the collector's shutdown, so the coordinator finishes its batch and
	/// closes the database.
	public func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
		Task {
			await controller.terminate()
			application.reply(toApplicationShouldTerminate: true)
		}
		return .terminateLater
	}
}
