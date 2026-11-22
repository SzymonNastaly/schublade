import ApplicationBindings

/// Everything a screen asks of the collector. Each command throws the one refusal it can answer.
protocol CollectorCommands {
	func enrollFolder(root: String) async throws(EnrollmentRefusal) -> FolderReference
	func withdrawFolder(_ folder: FolderIdentifier) async throws(WithdrawalRefusal)
	func decideBacklog(_ folder: FolderIdentifier) async throws(DecisionRefusal)
}
