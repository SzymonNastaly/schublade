/// Trailing indicator shown on a sidebar row.
public enum SidebarRowAccessory: Equatable, Sendable {
	case none
	case count(String)
	case symbol(name: String, tone: StatusLineTone)
}
