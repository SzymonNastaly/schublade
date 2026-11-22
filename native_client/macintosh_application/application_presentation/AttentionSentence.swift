/// One item of Needs Attention in plain words, with the control that resolves it.
public struct AttentionSentence: Equatable, Sendable {
	public let text: String
	public let tone: CollectorTone
	/// `nil` when nothing the person does here resolves the item.
	public let action: AttentionAction?

	public init(text: String, tone: CollectorTone, action: AttentionAction?) {
		self.text = text
		self.tone = tone
		self.action = action
	}
}
