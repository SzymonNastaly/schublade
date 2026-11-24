import ApplicationBindings

/// The orders of Sort By, each under its title, in the order of the menu. A menu item's tag is its
/// order's place in this list, in the toolbar's menu and in View alike.
public enum SortOrderMenu {
	public static let entries: [(order: ListingOrder, title: String)] = [
		(.documentDate, "Date on Document"),
		(.addition, "Date Added"),
		(.title, "Title"),
		(.sender, "Sender"),
	]

	public static func order(forTag tag: Int) -> ListingOrder? {
		entries.indices.contains(tag) ? entries[tag].order : nil
	}

	public static func tag(of order: ListingOrder) -> Int? {
		entries.firstIndex { $0.order == order }
	}
}
