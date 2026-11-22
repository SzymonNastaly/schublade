import ApplicationBindings

/// The one owner of the application's situations. It starts the core, follows both the library and
/// collector statuses in order, and renders the window and menu bar item after each change.
final class ApplicationController {
	private(set) var situation = ApplicationSituation.starting
	let statusItem: StatusItemController
	let mainWindowController: MainWindowController
	let environment: ApplicationEnvironment
	private let gateway: ApplicationGateway
	private var shownContentRevision: UInt64 = 0

	var applicationCommands: any ApplicationCommands {
		gateway
	}

	var libraryQueries: any LibraryQueries {
		gateway
	}

	var collectorCommands: any CollectorCommands {
		gateway
	}

	init(environment: ApplicationEnvironment) {
		let gateway = ApplicationGateway()
		let statusItem = StatusItemController()
		let mainWindowController = MainWindowController(
			applicationCommands: gateway,
			libraryQueries: gateway
		) { attended in
			gateway.interfaceAttended(attended)
		}

		self.environment = environment
		self.gateway = gateway
		self.statusItem = statusItem
		self.mainWindowController = mainWindowController

		statusItem.onOpenWindow = { [weak mainWindowController] in
			mainWindowController?.present()
		}

		statusItem.render(situation)
		mainWindowController.render(situation)
	}

	func launch() {
		mainWindowController.present()
		Task {
			await followApplication()
		}
	}

	func showMainWindow() {
		mainWindowController.present()
	}

	func terminate() async {
		await gateway.shutdown()
	}

	private func followApplication() async {
		do {
			try await gateway.start(configuration: environment.applicationConfiguration)
		} catch {
			change(to: .failedToStart(error))
			return
		}
		gateway.interfaceAttended(mainWindowController.isAttending)
		async let libraryFollowing: Void = followLibrary()
		async let collectorFollowing: Void = followCollector()
		_ = await (libraryFollowing, collectorFollowing)
		change(to: .stopped)
	}

	private func followLibrary() async {
		var revision: UInt64?
		while let status = try? await gateway.libraryStatusAfter(revision) {
			revision = status.revision
			updateRunning { $0.library = status }
			if status.contentRevision != shownContentRevision {
				shownContentRevision = status.contentRevision
				mainWindowController.contentRevisionChanged(to: shownContentRevision)
			}
		}
	}

	private func followCollector() async {
		var revision: UInt64?
		while let status = try? await gateway.collectorStatusAfter(revision) {
			revision = status.revision
			updateRunning { $0.collector = status }
		}
	}

	private func updateRunning(_ mutate: (inout ApplicationStatuses) -> Void) {
		var statuses: ApplicationStatuses = if case let .running(current) = situation {
			current
		} else {
			ApplicationStatuses()
		}
		mutate(&statuses)
		change(to: .running(statuses))
	}

	private func change(to nextSituation: ApplicationSituation) {
		guard nextSituation != situation else {
			return
		}
		situation = nextSituation
		statusItem.render(nextSituation)
		mainWindowController.render(nextSituation)
	}
}
