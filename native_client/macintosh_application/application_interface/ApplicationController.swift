import ApplicationBindings

/// The one owner of the collector's situation. It starts the collector, follows every status in
/// order, and renders the menu bar item after each change.
final class ApplicationController {
	private(set) var situation = CollectorSituation.starting
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
			await followCollector()
		}
	}

	func terminate() async {
		await gateway.shutdown()
	}

	private func followCollector() async {
		do {
			try await gateway.start(configuration: environment.collectorConfiguration)
		} catch {
			change(to: .failedToStart(error))
			return
		}
		var revision: UInt64?
		while let status = try? await gateway.statusAfter(revision) {
			revision = status.revision
			change(to: .running(status))
		}
		change(to: .stopped)
	}

	private func change(to situation: CollectorSituation) {
		self.situation = situation
		statusItem.render(situation)
	}
}
