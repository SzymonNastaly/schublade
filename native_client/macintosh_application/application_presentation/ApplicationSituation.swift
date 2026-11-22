import ApplicationBindings

/// What the application knows of the core. Only `ApplicationController` changes it.
public enum ApplicationSituation: Equatable, Sendable {
	case starting
	case failedToStart(ApplicationStartFailure)
	case running(ApplicationStatuses)
	case stopped
}
