/// One selectable item in the library sidebar.
public struct SidebarItemPresentation: Equatable, Identifiable, Sendable {
	public let id: String
	public let title: String
	public let symbolName: String
	public let accessory: SidebarRowAccessory
	public let kind: SidebarItemKind

	public init(
		identifier: String,
		title: String,
		symbolName: String,
		accessory: SidebarRowAccessory,
		kind: SidebarItemKind
	) {
		id = identifier
		self.title = title
		self.symbolName = symbolName
		self.accessory = accessory
		self.kind = kind
	}
}
