/// One read-only file fact displayed in the bottom File section of the inspector.
public struct InspectorFileFact: Equatable, Sendable {
	public let label: String
	public let value: String

	public init(label: String, value: String) {
		self.label = label
		self.value = value
	}
}
