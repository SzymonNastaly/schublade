import AppKit
import ApplicationPresentation
import os

public final class ApplicationDelegate: NSObject, NSApplicationDelegate {
	private static let log = Logger(subsystem: "org.schublade.application", category: "lifecycle")

	let controller = ApplicationController(environment: .current())
	/// Set once a quit goes on, so a second Command-Q while the cores shut down neither asks again
	/// nor shuts them down twice.
	private var isTerminating = false

	public func applicationWillFinishLaunching(_: Notification) {
		// A copy started outside Launch Services finds the first one, shows its window, and ends.
		// Launch Services itself turns a second open into a reopen of the first. An isolated copy
		// keeps its own temporary state, so it runs beside another, as the end-to-end test does.
		guard !controller.environment.isIsolated else {
			return
		}
		let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
			.filter { $0 != NSRunningApplication.current && !$0.isTerminated }
		if let first = others.first, let location = first.bundleURL {
			// Opening the running copy through Launch Services reopens it, which shows its window.
			NSWorkspace.shared.openApplication(at: location, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
				exit(0)
			}
		}
	}

	public func applicationDidFinishLaunching(_: Notification) {
		MainMenuBuilder.installMainMenu { [weak self] in
			self?.controller.mainWindowController.workspaceController?.shareableItems() ?? []
		}
		let origin = Self.launchOrigin()
		Self.log.info("Launched by \(origin == .loginItem ? "the login item" : "a person", privacy: .public)")
		NSWorkspace.shared.notificationCenter.addObserver(
			self,
			selector: #selector(systemDidWake),
			name: NSWorkspace.didWakeNotification,
			object: nil
		)
		controller.launch(origin: origin)
	}

	public func applicationDidBecomeActive(_: Notification) {
		controller.applicationActivated()
	}

	public func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		controller.showMainWindow()
		return false
	}

	/// Terminating waits for the shutdown of both cores, so each coordinator finishes its batch and
	/// closes its database. The first quit while folders are collected asks first, because quitting
	/// stops collecting.
	public func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
		guard !isTerminating else {
			return .terminateLater
		}
		guard confirmsQuitting() else {
			return .terminateCancel
		}
		isTerminating = true
		Task {
			await controller.terminate()
			application.reply(toApplicationShouldTerminate: true)
		}
		return .terminateLater
	}

	@objc func showSettings(_: Any?) {
		controller.showSettings()
	}

	@objc func showLibraryWindow(_: Any?) {
		controller.showMainWindow()
	}

	@objc private func systemDidWake(_: Notification) {
		controller.systemResumed()
	}

	/// The launch Apple event says whether the login item started the application.
	private static func launchOrigin() -> LaunchOrigin {
		let event = NSAppleEventManager.shared().currentAppleEvent
		let launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
			&& event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
			== OSType(keyAELaunchedAsLogInItem)
		return launchedAtLogin ? .loginItem : .person
	}

	/// Answers whether quitting goes on. While folders are collected, a person's quit asks first,
	/// because quitting stops collecting; Close Window keeps collecting instead. A logout, a
	/// restart, or a shutdown never asks.
	private func confirmsQuitting() -> Bool {
		let preferences = controller.preferences
		let quitBySystem = NSAppleEventManager.shared().currentAppleEvent?
			.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
		guard !quitBySystem, !controller.environment.isIsolated,
		      LifecyclePresentation.asksBeforeQuitting(
		      	situation: controller.situation,
		      	suppressed: preferences.quitAlertSuppressed
		      )
		else {
			return true
		}
		let alert = NSAlert()
		alert.messageText = "Schublade stops collecting when it quits"
		alert.informativeText = "New files in your folders upload only while Schublade is open. "
			+ "Close the window instead, and Schublade keeps collecting in the menu bar."
		alert.addButton(withTitle: "Quit")
		alert.addButton(withTitle: "Close Window")
		alert.showsSuppressionButton = true
		alert.suppressionButton?.title = "Do not ask again"
		// A quit from the menu bar item does not make the application active, and an alert behind
		// the front application would hold the quit with nothing on screen.
		NSApp.activate()
		let response = alert.runModal()
		if alert.suppressionButton?.state == .on {
			preferences.quitAlertSuppressed = true
		}
		guard response == .alertFirstButtonReturn else {
			controller.mainWindowController.close()
			return false
		}
		return true
	}
}
