public struct DeviceWording: Equatable, Sendable {
	public let phrase: String
	/// The limits a person picks from, in bytes, and nil for no limit.
	public let storageLimitChoices: [UInt64?]

	public init(phrase: String, storageLimitChoices: [UInt64?]) {
		self.phrase = phrase
		self.storageLimitChoices = storageLimitChoices
	}

	public var titlePhrase: String {
		phrase.prefix(1).uppercased() + phrase.dropFirst()
	}
}
