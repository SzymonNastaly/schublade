/// Plain explanation and suggested remedy when the core cannot start.
public struct StartFailureWording: Equatable, Sendable {
	public let explanation: String
	public let remedy: String
	public let detail: String?

	public init(explanation: String, remedy: String, detail: String?) {
		self.explanation = explanation
		self.remedy = remedy
		self.detail = detail
	}

	public var combinedSentence: String {
		guard !remedy.isEmpty else {
			return explanation
		}
		return "\(explanation) \(remedy)"
	}
}
