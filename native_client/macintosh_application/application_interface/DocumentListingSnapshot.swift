import ApplicationBindings

/// Read-only window into a document listing held in memory so views and tests stay decoupled from
/// the concrete bindings object.
public protocol DocumentListingSnapshot: AnyObject {
	func rowCount() -> UInt32
	func documentCount() -> UInt32
	func headingPositions() -> [UInt32]
	func contentRevision() -> UInt64
	func rows(first: UInt32, count: UInt32) -> [ListingRow]
	func positionOf(document: DocumentIdentifier) -> UInt32?
}

extension DocumentListing: DocumentListingSnapshot {}
