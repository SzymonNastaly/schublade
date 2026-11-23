import ApplicationBindings

/// One labeled field row in the inspector, optionally copyable and optionally linked to a scope.
public struct InspectorDetailRow: Equatable, Sendable {
	public let label: String
	public let displayValue: String
	public let copyValue: String?
	public let linkedScope: NamedScope?

	public init(
		label: String,
		displayValue: String,
		copyValue: String?,
		linkedScope: NamedScope?
	) {
		self.label = label
		self.displayValue = displayValue
		self.copyValue = copyValue
		self.linkedScope = linkedScope
	}
}
