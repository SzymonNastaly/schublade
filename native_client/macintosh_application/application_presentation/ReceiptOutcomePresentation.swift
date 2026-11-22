/// The badge of an upload's document: processing, archived, or failed.
public struct ReceiptOutcomePresentation: Equatable, Sendable {
	public let label: String
	public let tone: CollectorTone

	public init(label: String, tone: CollectorTone) {
		self.label = label
		self.tone = tone
	}
}
