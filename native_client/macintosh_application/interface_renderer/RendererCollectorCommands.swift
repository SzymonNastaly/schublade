import ApplicationBindings
import ApplicationInterface

/// Inert `CollectorCommands` fake used by `InterfaceRenderer`.
final class RendererCollectorCommands: CollectorCommands {
	func enrollFolder(root _: String) async throws(EnrollmentRefusal) -> FolderReference {
		throw .Application(fault: .Stopped)
	}

	func withdrawFolder(_: FolderIdentifier) async throws(WithdrawalRefusal) {
		throw .Application(fault: .Stopped)
	}

	func decideBacklog(_: FolderIdentifier) async throws(DecisionRefusal) {
		throw .Application(fault: .Stopped)
	}
}
