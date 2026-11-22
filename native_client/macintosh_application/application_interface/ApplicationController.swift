import ApplicationBindings

/// The one owner of the application's situations. It starts the core, follows both the library and
/// collector statuses in order, and renders the menu bar item after each collector change.
final class ApplicationController {
	private(set) var situation = CollectorSituation.starting
	private(set) var libraryStatus: LibraryStatus?
	let statusItem = StatusItemController()
	let environment: ApplicationEnvironment
	private let gateway = CollectorGateway()

	var commands: any CollectorCommands {
		gateway
	}

	init(environment: ApplicationEnvironment) {
		self.environment = environment
		statusItem.render(situation)
	}

	func launch() {
		Task {
			await followApplication()
		}
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
		async let libraryFollowing: Void = followLibrary()
		async let collectorFollowing: Void = followCollector()
		_ = await (libraryFollowing, collectorFollowing)
		change(to: .stopped)
	}

	private func followLibrary() async {
		var revision: UInt64?
		while let status = try? await gateway.libraryStatusAfter(revision) {
			revision = status.revision
			libraryStatus = status
		}
	}

	private func followCollector() async {
		var revision: UInt64?
		while let status = try? await gateway.statusAfter(revision) {
			revision = status.revision
			change(to: .running(status))
		}
	}

	private func change(to situation: CollectorSituation) {
		self.situation = situation
		statusItem.render(situation)
	}
}
