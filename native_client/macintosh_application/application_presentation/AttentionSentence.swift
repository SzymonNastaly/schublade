/// One item of Needs Attention in plain words, with its symbol, the group it belongs to, and the
/// control that resolves it.
public struct AttentionSentence: Equatable, Sendable {
	public let text: String
	public let symbolName: String
	public let group: AttentionGroup
	/// `nil` when nothing the person does here resolves the item.
	public let action: AttentionAction?

	public init(text: String, symbolName: String, group: AttentionGroup, action: AttentionAction?) {
		self.text = text
		self.symbolName = symbolName
		self.group = group
		self.action = action
	}
}

/// Where what needs a person lies: a folder or a file on this Mac, or the archive's side.
public enum AttentionGroup: Equatable, Sendable {
	case thisMac
	case archive
}
