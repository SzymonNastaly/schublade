import ApplicationBindings

/// The latest status snapshots and transient faults reported by the library and collector loops.
struct ApplicationStatuses: Equatable {
	var library: LibraryStatus?
	var collector: CollectorStatus?
	var libraryFault: ApplicationFault?
	var collectorFault: ApplicationFault?
}
