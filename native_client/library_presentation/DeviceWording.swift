/// What the library's wording says differently on each device: how a sentence names the device, and
/// the limits its Settings offer for downloaded originals.
public struct DeviceWording: Equatable, Sendable {
	/// The device within a sentence, such as "this Mac" or "this iPhone".
	public let phrase: String
	/// The limits a person picks from, in bytes, and nil for no limit.
	public let storageLimitChoices: [UInt64?]

	public init(phrase: String, storageLimitChoices: [UInt64?]) {
		self.phrase = phrase
		self.storageLimitChoices = storageLimitChoices
	}

	/// The device within a title, such as "This Mac".
	public var titlePhrase: String {
		phrase.prefix(1).uppercased() + phrase.dropFirst()
	}
}
