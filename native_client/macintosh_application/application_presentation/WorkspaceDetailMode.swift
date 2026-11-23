import ApplicationBindings

/// Which workspace detail view occupies the content area beside the sidebar.
public enum WorkspaceDetailMode: Equatable, Sendable {
	case documents
	/// The archive holds no document; `offersFolders` while this Mac collects.
	case emptyArchive(offersFolders: Bool)
	case archiveOutdated(message: String)
	case tokenCannotRead(message: String)
	case needsAttention(summary: String)
	case folder(FolderIdentifier, name: String)
}
