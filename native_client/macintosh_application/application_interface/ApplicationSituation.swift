import ApplicationBindings

/// The latest snapshots received from the library and collector loops while the core runs.
struct ApplicationStatuses: Equatable {
	var library: LibraryStatus?
	var collector: CollectorStatus?
}

/// What the application knows of the core. Only `ApplicationController` changes it.
enum ApplicationSituation: Equatable {
	case starting
	case failedToStart(ApplicationStartFailure)
	case running(ApplicationStatuses)
	case stopped
}
