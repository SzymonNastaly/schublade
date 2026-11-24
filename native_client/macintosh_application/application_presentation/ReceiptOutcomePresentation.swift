/// The outcome of an upload's document as its row shows it: a mark, and the label beside the time
/// unless the mark says it alone.
public struct ReceiptOutcomePresentation: Equatable, Sendable {
	public let mark: CollectorStateMark
	/// The outcome in words, which the mark's accessibility description reads too.
	public let label: String
	public let tone: CollectorTone
	public let showsLabel: Bool

	public init(mark: CollectorStateMark, label: String, tone: CollectorTone, showsLabel: Bool) {
		self.mark = mark
		self.label = label
		self.tone = tone
		self.showsLabel = showsLabel
	}
}
