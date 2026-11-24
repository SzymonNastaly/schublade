/// A collected folder's state as the line under its name shows it: a mark, a label, and a sentence.
public struct FolderStatePresentation: Equatable, Sendable {
	public let mark: CollectorStateMark
	public let label: String
	public let tone: CollectorTone
	/// `nil` when the label says it all.
	public let detail: String?

	public init(mark: CollectorStateMark, label: String, tone: CollectorTone, detail: String?) {
		self.mark = mark
		self.label = label
		self.tone = tone
		self.detail = detail
	}
}

/// What stands before a folder's state or an upload's outcome: a small spinner while it lasts, or a
/// symbol.
public enum CollectorStateMark: Equatable, Sendable {
	case progress
	case symbol(String)
}
