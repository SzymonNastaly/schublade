import ApplicationPresentation

/// Reference-stable outline node representing one selectable row in the sidebar.
final class SidebarItemNode {
	var presentation: SidebarItemPresentation

	init(presentation: SidebarItemPresentation) {
		self.presentation = presentation
	}
}
