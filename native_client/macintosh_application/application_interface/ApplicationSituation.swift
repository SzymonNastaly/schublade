import ApplicationBindings

/// What the application knows of the core. Only `ApplicationController` changes it.
enum ApplicationSituation: Equatable {
	case starting
	case failedToStart(ApplicationStartFailure)
	case running(ApplicationStatuses)
	case stopped
}
