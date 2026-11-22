import ApplicationBindings

/// Plain user-facing sentences for application startup failures and runtime core faults.
enum ApplicationFailureWording {
	static func startFailureSentence(_ failure: ApplicationStartFailure) -> String {
		switch failure {
		case let .DataDirectoryUnavailable(detail):
			"Schublade could not create its folder in Application Support: \(detail)"
		case let .CacheDirectoryUnavailable(detail):
			"Schublade could not create its cache folder: \(detail)"
		case .DatabaseInUse:
			"Another copy of Schublade is already running on this Mac with the same data."
		case .DatabaseNewerThanApplication:
			"A newer version of Schublade ran on this Mac before, and this older version cannot read what it saved."
		case let .DatabaseUnusable(detail):
			"Schublade could not open its database: \(detail)"
		case let .WatcherUnavailable(detail):
			"Schublade could not start watching your folders: \(detail)"
		case let .Unexpected(detail):
			"Schublade could not start: \(detail)"
		}
	}

	static func faultSentence(_ fault: ApplicationFault) -> String {
		switch fault {
		case .Stopped:
			"Schublade stopped."
		case let .StoreFailed(detail):
			"Local storage error: \(detail)"
		case let .Unexpected(detail):
			"Unexpected application error: \(detail)"
		}
	}
}
