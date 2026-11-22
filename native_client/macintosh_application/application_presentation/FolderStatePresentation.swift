/// A collected folder's state as its badge and the sentence under its name show it.
public struct FolderStatePresentation: Equatable, Sendable {
	public let label: String
	public let tone: CollectorTone
	/// `nil` when the badge says it all.
	public let detail: String?

	public init(label: String, tone: CollectorTone, detail: String?) {
		self.label = label
		self.tone = tone
		self.detail = detail
	}
}
