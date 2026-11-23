import LibraryPresentation

enum IphoneDevice {
	/// The room the downloaded originals may take until a person chooses another.
	static let defaultOriginalStorageLimit: UInt64 = 500_000_000
	static let wording = DeviceWording(
		phrase: "this iPhone",
		storageLimitChoices: [250_000_000, defaultOriginalStorageLimit, 1_000_000_000, 2_000_000_000, nil]
	)
}
