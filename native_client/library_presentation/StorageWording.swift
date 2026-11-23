import Foundation

/// Settings > Storage: the room downloaded originals may take, and how much they take now.
public enum StorageWording {
	public static func limitTitle(_ bytes: UInt64?) -> String {
		guard let bytes else {
			return "No Limit"
		}
		return size(bytes)
	}

	public static func heldSentence(_ bytes: UInt64, device: DeviceWording) -> String {
		bytes == 0
			? "No originals are downloaded on \(device.phrase)."
			: "Downloaded originals take \(size(bytes)) on \(device.phrase)."
	}

	private static func size(_ bytes: UInt64) -> String {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
		return formatter.string(fromByteCount: Int64(clamping: bytes))
	}
}
