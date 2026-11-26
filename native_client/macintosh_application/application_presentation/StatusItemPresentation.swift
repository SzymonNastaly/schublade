import ApplicationBindings
import LibraryPresentation

/// What the menu bar item shows: its glyph and the rows of its menu that follow from the statuses.
/// The five newest documents are read from the library when the menu opens, so they are not here.
public struct StatusItemPresentation: Equatable, Sendable {
	public let glyph: StatusItemGlyph
	/// The status line's sentence without uploads, such as "Up to date · 14:02", and its symbol.
	public let statusSentence: String
	public let statusSymbolName: String
	/// "Uploading Tax assessment 2025.pdf" while one file is in flight, "Uploading 3 files" while more are.
	public let uploadSentence: String?
	public let attention: [AttentionSentence]
	/// Whether the menu offers Add Folder…, which needs a collector.
	public let offersAddFolder: Bool

	public init(
		glyph: StatusItemGlyph,
		statusSentence: String,
		statusSymbolName: String,
		uploadSentence: String?,
		attention: [AttentionSentence],
		offersAddFolder: Bool
	) {
		self.glyph = glyph
		self.statusSentence = statusSentence
		self.statusSymbolName = statusSymbolName
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
				statusSymbolName: "clock",
				uploadSentence: nil,
				attention: [],
				offersAddFolder: false
			)
		case let .failedToStart(failure):
			return StatusItemPresentation(
				glyph: .attentionRequired,
				statusSentence: ApplicationFailureWording.startFailureSentence(failure),
				statusSymbolName: "exclamationmark.triangle.fill",
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
			let statusLine = StatusLinePresentation.resolve(
				statuses: statuses,
				context: context,
				includesUploads: false
			)
			return StatusItemPresentation(
				glyph: glyph(statuses, uploading: fileInFlight != nil),
				statusSentence: statusLine.text,
				statusSymbolName: statusLine.symbolName,
				uploadSentence: uploadSentence(
					fileInFlight: fileInFlight,
					uploading: StatusLinePresentation.uploadingCount(collector: statuses.collector)
				),
				attention: statuses.attentionItems.map { CollectorWording.attentionSentence($0, context: context) },
				offersAddFolder: statuses.collector != nil
			)
		}
	}

	/// One line for the uploads: the file's name while it is the only one, otherwise the count.
	private static func uploadSentence(fileInFlight: String?, uploading: UInt64) -> String? {
		if uploading <= 1, let fileInFlight {
			return "Uploading \(fileInFlight)"
		}
		guard uploading > 0 else {
			return nil
		}
		return "Uploading \(DocumentFormatting.countText(uploading, singular: "file"))"
	}

	/// The line under a newest document's title in the menu: its sender and its short date, such as
	/// "Stadtwerke Talbrück GmbH · 22 Sep", or `nil` while the archive knows neither.
	public static func documentSubtitle(_ row: DocumentRow, context: ApplicationWordingContext) -> String? {
		let parts = [
			row.senderName.flatMap { $0.isEmpty ? nil : $0 },
			row.documentDate.map { DocumentFormatting.dayAndMonth($0, context: context.library) },
		].compactMap(\.self)
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}

	/// The precedence of the design: what only a person can settle, then the connection, then an
	/// upload, then rest. A refused file is listed in the menu but does not mark the menu bar.
	private static func glyph(_ statuses: ApplicationStatuses, uploading: Bool) -> StatusItemGlyph {
		let settledOnlyByAPerson = statuses.attentionItems.contains { item in
			switch item {
			case .credentialSuspended, .archiveOutdated, .folderUnavailable, .backlogAwaitsDecision:
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
