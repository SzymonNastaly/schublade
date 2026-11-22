import ApplicationBindings
import ApplicationInterface

/// Inert `ApplicationCommands` fake used when rendering `ConnectionFormViewController` offscreen.
final class RendererApplicationCommands: ApplicationCommands {
	func connectArchive(address _: String, token _: String) async throws(ConnectionRefusal) -> ConnectionGrant {
		throw .ArchiveUnreachable
	}
}
