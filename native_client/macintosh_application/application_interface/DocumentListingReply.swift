import ApplicationBindings

/// The new listing and optional difference returned by `LibraryQueries.listDocuments`.
public struct DocumentListingReply {
	public let listing: any DocumentListingSnapshot
	public let difference: ListingDifference?

	public init(listing: any DocumentListingSnapshot, difference: ListingDifference?) {
		self.listing = listing
		self.difference = difference
	}
}
