import Foundation

/// Hashable object key for `NSCache` without referencing `NSString`.
final class ThumbnailCacheKey: NSObject {
	let rawValue: String

	nonisolated init(_ rawValue: String) {
		self.rawValue = rawValue
	}

	override nonisolated var hash: Int {
		rawValue.hashValue
	}

	override nonisolated func isEqual(_ object: Any?) -> Bool {
		guard let other = object as? ThumbnailCacheKey else {
			return false
		}
		return rawValue == other.rawValue
	}
}
