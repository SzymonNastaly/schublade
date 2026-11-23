import ApplicationBindings
import LibraryPresentation

/// What the menu bar item shows: its glyph and the rows of its menu that follow from the statuses.
/// The five newest documents are read from the library when the menu opens, so they are not here.
public struct StatusItemPresentation: Equatable, Sendable {
	public let glyph: StatusItemGlyph
	/// The status line's sentence, such as "Up to date · 14:02".
	public let statusSentence: String
	/// "Uploading Tax assessment 2025.pdf" while a file is in flight.
	public let uploadSentence: String?
	public let attention: [AttentionSentence]
	/// Whether the menu offers Add Folder…, which needs a collector.
	public let offersAddFolder: Bool

	public init(
		glyph: StatusItemGlyph,
		statusSentence: String,
		uploadSentence: String?,
		attention: [AttentionSentence],
		offersAddFolder: Bool
	) {
		self.glyph = glyph
		self.statusSentence = statusSentence
		self.uploadSentence = uploadSentence
		self.attention = attention
		self.offersAddFolder = offersAddFolder
	}

	public static func resolve(
		situation: ApplicationSituation,
		context: ApplicationWordingContext
	) -> StatusItemPresentation {
		switch situation {
		case .starting, .stopped:
			return StatusItemPresentation(
				glyph: .starting,
				statusSentence: situation == .stopped ? "Stopped" : "Starting",
				uploadSentence: nil,
				attention: [],
				offersAddFolder: false
			)
		case let .failedToStart(failure):
			return StatusItemPresentation(
				glyph: .attentionRequired,
				statusSentence: ApplicationFailureWording.startFailureSentence(failure),
				uploadSentence: nil,
				attention: [],
				offersAddFolder: false
			)
		case let .running(statuses):
			let fileInFlight = statuses.collector?.activities.lazy.compactMap { activity in
				if case let .submitting(fileName, _) = activity {
					return fileName
				}
				return nil
			}.first
			return StatusItemPresentation(
				glyph: glyph(statuses, uploading: fileInFlight != nil),
				statusSentence: StatusLinePresentation.resolve(statuses: statuses, context: context).text,
				uploadSentence: fileInFlight.map { "Uploading \($0)" },
				attention: statuses.attentionItems.map { CollectorWording.attentionSentence($0, context: context) },
				offersAddFolder: statuses.collector != nil
			)
		}
	}

	/// The precedence of the design: what only a person can settle, then the connection, then an
	/// upload, then rest. A refused file is listed in the menu but does not mark the menu bar.
	private static func glyph(_ statuses: ApplicationStatuses, uploading: Bool) -> StatusItemGlyph {
		let settledOnlyByAPerson = statuses.attentionItems.contains { item in
			switch item {
			case .credentialSuspended, .folderUnavailable, .backlogAwaitsDecision:
				true
			case .contentRefused, .contentFailing:
				false
			}
		}
		if settledOnlyByAPerson {
			return .attentionRequired
		}
		guard let library = statuses.library else {
			return statuses.libraryFault == nil ? .starting : .attentionRequired
		}
		switch library.archive {
		case .notConfigured:
			return .archiveNotConnected
		case let .configured(_, _, condition, _, _):
			switch condition {
			case .unreachable, .deferred, .checking:
				return .archiveUnreachable
			case .connected, .suspended, .archiveOutdated:
				return uploading ? .submitting : .resting
			}
		}
	}
}
