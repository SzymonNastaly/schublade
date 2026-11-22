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
		let collectorItems = UInt64(collector?.attention.count ?? 0)
		let extraSuspended: UInt64 = hasUnreportedSuspension ? 1 : 0
		return collectorItems + failedDocuments + extraSuspended
	}

	private var hasUnreportedSuspension: Bool {
		guard let library, case let .configured(_, _, condition, _, _) = library.archive,
		      case .suspended = condition
		else {
			return false
		}
		let collectorReported = collector?.attention.contains { item in
			if case .credentialSuspended = item {
				return true
			}
			return false
		}
		return collectorReported != true
	}
}
