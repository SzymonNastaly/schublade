import ApplicationBindings
import LibraryPresentation

/// What the window shows before the library can: Schublade starting, failing to start, a library
/// that failed, or the application stopped.
public extension EmptyStatePresentation {
	static let starting = EmptyStatePresentation(
		picture: .progress,
		title: "Starting Schublade…",
		detail: "",
		action: nil
	)

	static let stopped = EmptyStatePresentation(
		picture: .symbol("stop.circle"),
		title: "Schublade Stopped",
		detail: "Quit Schublade and open it again.",
		action: nil
	)

	static func startFailure(_ failure: ApplicationStartFailure) -> EmptyStatePresentation {
		EmptyStatePresentation(
			picture: .symbol("exclamationmark.triangle"),
			title: "Schublade Could Not Start",
			detail: ApplicationFailureWording.startFailureWording(failure).combinedSentence,
			action: nil
		)
	}

	static func libraryFault(_ fault: ApplicationFault) -> EmptyStatePresentation {
		EmptyStatePresentation(
			picture: .symbol("exclamationmark.triangle"),
			title: "Library Unavailable",
			detail: LibraryFailureWording.faultSentence(fault),
			action: nil
		)
	}
}
