import ApplicationBindings
import ApplicationInterface

/// Inert `ApplicationCommands` for the connection form offscreen, which never connects.
final class RendererApplicationCommands: ApplicationCommands {
	func connectArchive(address _: String, token _: String) async throws(ConnectionRefusal) -> ConnectionGrant {
		throw .ArchiveUnreachable
	}
}
