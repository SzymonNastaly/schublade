import ApplicationBindings
import Foundation

/// The single status line at the foot of the sidebar, resolved in strict precedence order.
public struct StatusLinePresentation: Equatable, Sendable {
	public let symbolName: String
	public let text: String
	public let tone: StatusLineTone
	public let progress: Double?
	public let allowsTokenReplacement: Bool
	public let allowsSynchronize: Bool

	public init(
		symbolName: String,
		text: String,
		tone: StatusLineTone,
		progress: Double?,
		allowsTokenReplacement: Bool,
		allowsSynchronize: Bool
	) {
		self.symbolName = symbolName
		self.text = text
		self.tone = tone
		self.progress = progress
		self.allowsTokenReplacement = allowsTokenReplacement
		self.allowsSynchronize = allowsSynchronize
	}

	public static func resolve(
		statuses: ApplicationStatuses,
		context: WordingContext
	) -> StatusLinePresentation {
		if let fault = statuses.libraryFault ?? statuses.collectorFault {
			return StatusLinePresentation(
				symbolName: "exclamationmark.triangle.fill",
				text: ApplicationFailureWording.faultSentence(fault),
				tone: .attention,
				progress: nil,
				allowsTokenReplacement: false,
				allowsSynchronize: false
			)
		}
		guard let library = statuses.library else {
			return StatusLinePresentation(
				symbolName: "clock",
				text: "Starting…",
				tone: .normal,
				progress: nil,
				allowsTokenReplacement: false,
				allowsSynchronize: false
			)
		}
		switch library.archive {
		case .notConfigured:
			return StatusLinePresentation(
				symbolName: "minus.circle",
				text: "Not connected",
				tone: .normal,
				progress: nil,
				allowsTokenReplacement: false,
				allowsSynchronize: false
			)
		case let .configured(_, _, condition, permission, _):
			return resolveConfigured(
				condition: condition,
				permission: permission,
				copy: library.copy,
				collector: statuses.collector,
				context: context
			)
		}
	}

	private static func resolveConfigured(
		condition: ConnectionCondition,
		permission: ArchivePermission,
		copy: LibraryCopy,
		collector: CollectorStatus?,
		context: WordingContext
	) -> StatusLinePresentation {
		if let issueStatus = issuePresentation(
			condition: condition,
			permission: permission,
			copy: copy,
			context: context
		) {
			return issueStatus
		}
		if case let .filling(received, remaining) = copy {
			return fillingPresentation(received: received, remaining: remaining)
		}
		if let uploading = uploadingCount(collector: collector), uploading > 0 {
			return StatusLinePresentation(
				symbolName: "arrow.up.circle.fill",
				text: "Uploading \(DocumentFormatting.countText(uploading, singular: "file"))",
				tone: .active,
				progress: nil,
				allowsTokenReplacement: false,
				allowsSynchronize: true
			)
		}
		return completeOrCheckingPresentation(copy: copy, context: context)
	}

	private static func fillingPresentation(received: UInt64, remaining: UInt64) -> StatusLinePresentation {
		let total = received + remaining
		let text = if total == 0 {
			"Loading…"
		} else if remaining == 0 {
			"Loading · \(DocumentFormatting.groupedNumber(received))"
		} else {
			"Loading · \(DocumentFormatting.groupedNumber(received)) of \(DocumentFormatting.groupedNumber(total))"
		}
		let fraction = total > 0 ? min(1, max(0, Double(received) / Double(total))) : nil
		return StatusLinePresentation(
			symbolName: "arrow.triangle.2.circlepath",
			text: text,
			tone: .active,
			progress: fraction,
			allowsTokenReplacement: false,
			allowsSynchronize: true
		)
	}

	private static func issuePresentation(
		condition: ConnectionCondition,
		permission: ArchivePermission,
		copy: LibraryCopy,
		context: WordingContext
	) -> StatusLinePresentation? {
		switch condition {
		case let .suspended(reason):
			let text = reason == .credentialRefused ? "Token refused" : "Token lacks permission"
			return StatusLinePresentation(
				symbolName: "exclamationmark.triangle.fill",
				text: text,
				tone: .attention,
				progress: nil,
				allowsTokenReplacement: true,
				allowsSynchronize: false
			)
		case .archiveOutdated:
			return StatusLinePresentation(
				symbolName: "exclamationmark.triangle.fill",
				text: "Archive update required",
				tone: .attention,
				progress: nil,
				allowsTokenReplacement: false,
				allowsSynchronize: true
			)
		case .unreachable, .deferred:
			return deferredOrOfflinePresentation(condition: condition, copy: copy, context: context)
		case .connected, .checking:
			guard permission == .collectOnly else {
				return nil
			}
			return StatusLinePresentation(
				symbolName: "tray.and.arrow.down",
				text: "Collector only",
				tone: .normal,
				progress: nil,
				allowsTokenReplacement: true,
				allowsSynchronize: false
			)
		}
	}

	private static func deferredOrOfflinePresentation(
		condition: ConnectionCondition,
		copy: LibraryCopy,
		context: WordingContext
	) -> StatusLinePresentation {
		let prefix = if case .deferred = condition {
			"Archive busy"
		} else {
			"Offline"
		}
		let suffix = if case let .complete(synchronizedAt) = copy {
			" · updated \(DocumentFormatting.clockTime(synchronizedAt, context: context))"
		} else {
			""
		}
		return StatusLinePresentation(
			symbolName: "wifi.slash",
			text: "\(prefix)\(suffix)",
			tone: .normal,
			progress: nil,
			allowsTokenReplacement: false,
			allowsSynchronize: true
		)
	}

	private static func completeOrCheckingPresentation(
		copy: LibraryCopy,
		context: WordingContext
	) -> StatusLinePresentation {
		switch copy {
		case let .complete(synchronizedAt):
			StatusLinePresentation(
				symbolName: "checkmark.circle",
				text: "Up to date · \(DocumentFormatting.clockTime(synchronizedAt, context: context))",
				tone: .normal,
				progress: nil,
				allowsTokenReplacement: false,
				allowsSynchronize: true
			)
		case .absent, .filling:
			StatusLinePresentation(
				symbolName: "arrow.triangle.2.circlepath",
				text: "Checking archive…",
				tone: .active,
				progress: nil,
				allowsTokenReplacement: false,
				allowsSynchronize: true
			)
		}
	}

	private static func uploadingCount(collector: CollectorStatus?) -> UInt64? {
		guard let collector else {
			return nil
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
		let count = max(submittingCount, awaiting)
		return count > 0 ? count : nil
	}
}
