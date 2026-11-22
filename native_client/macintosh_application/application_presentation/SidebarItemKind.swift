/// What clicking a sidebar item does.
public enum SidebarItemKind: Equatable, Hashable, Sendable {
	case destination(NavigationDestination)
	case addFolder
}
