/// One collapsible section of the library sidebar.
public struct SidebarSectionPresentation: Equatable, Identifiable, Sendable {
	public let id: String
	public let title: String
	public let items: [SidebarItemPresentation]

	public init(identifier: String, title: String, items: [SidebarItemPresentation]) {
		id = identifier
		self.title = title
		self.items = items
	}
}
