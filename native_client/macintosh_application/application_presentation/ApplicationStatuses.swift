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
}
