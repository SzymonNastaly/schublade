import LibraryPresentation

/// What the library's wording says of this Mac.
public enum MacintoshDevice {
	/// Two gigabytes by default, the second choice.
	public static let wording = DeviceWording(
		phrase: "this Mac",
		storageLimitChoices: [1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, nil]
	)
}
