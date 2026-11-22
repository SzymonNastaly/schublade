import ApplicationBindings

/// Which workspace detail view occupies the content area beside the sidebar.
public enum WorkspaceDetailMode: Equatable, Sendable {
	case documents
	case archiveOutdated(message: String)
	case tokenCannotRead(message: String)
	case needsAttention(summary: String)
	case folder(FolderIdentifier, name: String)
}
