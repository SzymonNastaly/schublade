import ApplicationBindings
import ApplicationInterface

/// Downloaded originals of a household's year, for Settings > Storage offscreen.
final class RendererStorageCommands: StorageCommands {
	func originalStorage() async throws(ApplicationFault) -> OriginalStorage {
		OriginalStorage(heldBytes: 1_284_000_000, limitBytes: 2_000_000_000)
	}

	func setOriginalStorageLimit(_: UInt64?) async throws(ApplicationFault) {}

	func removeDownloadedOriginals() async throws(ApplicationFault) {}
}

/// A menu bar item that is shown, without putting one into the menu bar.
final class RendererStatusItemVisibility: StatusItemVisibility {
	var isVisible = true
}
