import ApplicationBindings
import LibraryPresentation

public extension StatusLinePresentation {
	static func resolve(statuses: ApplicationStatuses, context: ApplicationWordingContext) -> StatusLinePresentation {
		if readsCollectorOnly(statuses) {
			return collectorOnlyPresentation
		}
		return resolve(
			library: statuses.library,
			fault: statuses.libraryFault ?? statuses.collectorFault,
			uploadingFiles: uploadingCount(collector: statuses.collector),
			context: context.library
		)
	}

	private static let collectorOnlyPresentation = StatusLinePresentation(
		symbolName: "tray.and.arrow.down",
		text: "Collector only",
		tone: .normal,
		progress: nil,
		allowsTokenReplacement: true,
		allowsSynchronize: false
	)

	/// A connected token that can only add documents, while no fault or other condition of the
	/// connection says more.
	private static func readsCollectorOnly(_ statuses: ApplicationStatuses) -> Bool {
		guard statuses.libraryFault == nil, statuses.collectorFault == nil, let library = statuses.library,
		      case let .configured(_, _, condition, permission, _) = library.archive,
		      permission == .collectOnly
		else {
			return false
		}
		switch condition {
		case .connected, .checking:
			return true
		case .suspended, .archiveOutdated, .unreachable, .deferred:
			return false
		}
	}

	private static func uploadingCount(collector: CollectorStatus?) -> UInt64 {
		guard let collector else {
			return 0
		}
		let submittingCount = collector.activities.reduce(into: UInt64(0)) { partial, activity in
			if case .submitting = activity {
				partial += 1
			}
		}
		let allCollecting = collector.folders.allSatisfy { folder in
			if case .collecting = folder.admission {
				return true
			}
			return false
		}
		let awaiting = allCollecting ? collector.progress.documentsAwaitingSubmission : 0
		return max(submittingCount, awaiting)
	}
}
