import ApplicationBindings

/// What the application knows of the collector. Only `ApplicationController` changes it.
enum CollectorSituation {
	case starting
	case failedToStart(ApplicationStartFailure)
	case running(CollectorStatus)
	case stopped
}
