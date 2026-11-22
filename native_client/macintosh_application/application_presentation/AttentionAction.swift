import ApplicationBindings

/// What an attention item asks the person to do, so the page can offer the matching control.
public enum AttentionAction: Equatable, Hashable, Sendable {
	case replaceToken
	case decideBacklog(FolderIdentifier)
	case openFolder(FolderIdentifier)
}
