/// One notification: what it says and the page a click opens. Its identifier names the event, so a
/// second notification of the same event replaces the first in Notification Center.
public struct CollectorNotice: Equatable, Sendable {
	public let identifier: String
	public let title: String
	public let body: String
	public let action: AttentionAction

	public init(identifier: String, title: String, body: String, action: AttentionAction) {
		self.identifier = identifier
		self.title = title
		self.body = body
		self.action = action
	}
}
