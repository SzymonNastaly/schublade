import ApplicationBindings

/// The latest status snapshots and transient faults reported by the library and collector loops.
public struct ApplicationStatuses: Equatable, Sendable {
	public var library: LibraryStatus?
	public var collector: CollectorStatus?
	public var libraryFault: ApplicationFault?
	public var collectorFault: ApplicationFault?

	public init(
		library: LibraryStatus? = nil,
		collector: CollectorStatus? = nil,
		libraryFault: ApplicationFault? = nil,
		collectorFault: ApplicationFault? = nil
	) {
		self.library = library
		self.collector = collector
		self.libraryFault = libraryFault
		self.collectorFault = collectorFault
	}

	/// What Needs Attention holds: the collector's items, the failed documents, and a refused token
	/// the collector has not reported, so the sidebar's count and the page agree.
	public func attentionCount(failedDocuments: UInt64) -> UInt64 {
		UInt64(attentionItems.count) + failedDocuments
	}

	/// The collector's attention items, led by a token the library found refused while the
	/// collector, which may be absent or not have asked yet, does not report it.
	public var attentionItems: [AttentionItem] {
		let items = collector?.attention ?? []
		let reported = items.contains { item in
			guard case .credentialSuspended = item else {
				return false
			}
			return true
		}
		guard !reported, let library, case let .configured(_, _, condition, _, _) = library.archive,
		      case let .suspended(reason) = condition
		else {
			return items
		}
		return [.credentialSuspended(reason: reason)] + items
	}
}
