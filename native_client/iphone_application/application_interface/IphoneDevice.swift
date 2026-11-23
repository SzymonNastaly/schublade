import LibraryPresentation

/// What the library's wording says of this iPhone.
enum IphoneDevice {
	/// 500 MB by default, the second choice, as the installed environment starts with.
	static let wording = DeviceWording(
		phrase: "this iPhone",
		storageLimitChoices: [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, nil]
	)
}
