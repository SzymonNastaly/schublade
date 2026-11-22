import Foundation

/// Settings > Storage: the room downloaded originals may take, and how much they take now.
public enum StorageWording {
	/// The limits a person picks from, in bytes, and nil for no limit; two gigabytes by default.
	public static let limitChoices: [UInt64?] = [1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, nil]

	public static func limitTitle(_ bytes: UInt64?) -> String {
		guard let bytes else {
			return "No Limit"
		}
		return size(bytes)
	}

	public static func heldSentence(_ bytes: UInt64) -> String {
		bytes == 0
			? "No originals are downloaded on this Mac."
			: "Downloaded originals take \(size(bytes)) on this Mac."
	}

	private static func size(_ bytes: UInt64) -> String {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
		return formatter.string(fromByteCount: Int64(clamping: bytes))
	}
}
