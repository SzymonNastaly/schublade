/// Files of a folder's survey that are not uploaded for one reason, as the confirmation lists them.
public struct SkippedGroup: Equatable, Sendable {
	/// "Not a PDF, JPEG, PNG, or WebP file".
	public let reason: String
	/// "31 files", or "12 items" when the group can hold folders, packages, or links.
	public let count: String

	public init(reason: String, count: String) {
		self.reason = reason
		self.count = count
	}
}
