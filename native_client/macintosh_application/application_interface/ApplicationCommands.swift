import ApplicationBindings

/// Everything a screen asks of the application root. Each command throws the one refusal it can
/// answer.
protocol ApplicationCommands {
	func connectArchive(address: String, token: String) async throws(ConnectionRefusal) -> ConnectionGrant
}
