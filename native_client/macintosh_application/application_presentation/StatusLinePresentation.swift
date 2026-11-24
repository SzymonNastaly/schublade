import ApplicationBindings
import LibraryPresentation

public extension StatusLinePresentation {
	/// The sidebar's line, which says that files upload. The menu bar's menu says that on a line of
	/// its own, so it passes `includesUploads: false`.
	static func resolve(
		statuses: ApplicationStatuses,
		context: ApplicationWordingContext,
		includesUploads: Bool = true
	) -> StatusLinePresentation {
		if readsCollectorOnly(statuses) {
			return collectorOnlyPresentation
		}
		return resolve(
			library: statuses.library,
			fault: statuses.libraryFault ?? statuses.collectorFault,
			uploadingFiles: includesUploads ? uploadingCount(collector: statuses.collector) : 0,
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

	/// The files in flight, or every file awaiting its upload once each folder collects.
	internal static func uploadingCount(collector: CollectorStatus?) -> UInt64 {
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
