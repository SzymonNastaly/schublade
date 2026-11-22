import ApplicationPresentation

/// Reference-stable outline node representing one collapsible section in the sidebar.
final class SidebarSectionNode {
	var presentation: SidebarSectionPresentation
	var itemNodes: [SidebarItemNode]

	init(presentation: SidebarSectionPresentation, itemNodes: [SidebarItemNode]) {
		self.presentation = presentation
		self.itemNodes = itemNodes
	}
}
