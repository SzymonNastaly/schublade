/// Trailing indicator shown on a sidebar row: a count, or what is unusual about a folder.
public enum SidebarRowAccessory: Equatable, Sendable {
	case none
	case count(String)
	/// A small spinner, such as a folder under survey.
	case inProgress(description: String)
	/// A symbol in the attention colour, such as a folder that waits for a decision.
	case attention(symbolName: String, description: String)
}
