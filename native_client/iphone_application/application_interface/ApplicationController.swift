import ApplicationBindings
import Observation

/// Owns the gateway and the state every screen reads: whether the core started, and the newest
/// library status it published.
@Observable
final class ApplicationController {
	enum Situation: Equatable {
		case starting
		case failedToStart(String)
		case running(LibraryStatus)
	}

	let environment: ApplicationEnvironment
	let gateway = ApplicationGateway()
	private(set) var situation = Situation.starting

	init(environment: ApplicationEnvironment) {
		self.environment = environment
	}

	func launch() {
		Task {
			do throws(ApplicationStartFailure) {
				try await gateway.start(configuration: environment.applicationConfiguration)
			} catch {
				situation = .failedToStart(String(describing: error))
				return
			}
			await followLibrary()
		}
	}

	/// Follows the library's status until the core stops.
	private func followLibrary() async {
		var revision: UInt64?
		while true {
			do throws(ApplicationFault) {
				let status = try await gateway.libraryStatusAfter(revision)
				revision = status.revision
				situation = .running(status)
			} catch {
				return
			}
		}
	}
}
