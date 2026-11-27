import Foundation

/// Settings > Storage: the room downloaded originals may take, and how much they take now.
public enum StorageWording {
	public static func limitTitle(_ bytes: UInt64?) -> String {
		guard let bytes else {
			return "No Limit"
		}
		return DocumentFormatting.byteSize(bytes, fractionLength: 0)
	}

	public static func heldSentence(_ bytes: UInt64, device: DeviceWording) -> String {
		bytes == 0
			? "No originals are downloaded on \(device.phrase)."
			: "Downloaded originals take \(DocumentFormatting.byteSize(bytes)) on \(device.phrase)."
	}
}
