/// What the reader displays when an original file or its extracted text cannot be shown.
public struct RepresentationPlaceholder: Equatable, Sendable {
	public let title: String
	public let detail: String
	public let canRetry: Bool
	public let allowsTokenReplacement: Bool

	public init(
		title: String,
		detail: String,
		canRetry: Bool,
		allowsTokenReplacement: Bool
	) {
		self.title = title
		self.detail = detail
		self.canRetry = canRetry
		self.allowsTokenReplacement = allowsTokenReplacement
	}
}
