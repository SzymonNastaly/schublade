import ApplicationBindings

/// What Settings > Storage asks of the library's downloaded originals.
public protocol StorageCommands {
	func originalStorage() async throws(ApplicationFault) -> OriginalStorage
	func setOriginalStorageLimit(_ bytes: UInt64?) async throws(ApplicationFault)
	func removeDownloadedOriginals() async throws(ApplicationFault)
}
