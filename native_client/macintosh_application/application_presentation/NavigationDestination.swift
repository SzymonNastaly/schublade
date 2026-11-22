import ApplicationBindings

/// Where the main window's sidebar selection points.
public enum NavigationDestination: Equatable, Hashable, Sendable {
	case library(LibraryScope, title: String?)
	case needsAttention
	case folder(FolderIdentifier)
}
