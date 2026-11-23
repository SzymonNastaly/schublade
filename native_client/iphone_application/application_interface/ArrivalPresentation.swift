import ApplicationBindings
import Foundation
import LibraryPresentation
import SubmissionQueue

/// A document a person sent from this iPhone, while its file is still being written, so its row
/// shows from the moment the camera closes.
nonisolated struct PreparingSubmission: Equatable {
	let identifier: UUID
	let origin: SubmissionOrigin
	/// The file's name as chosen, nil for a scan or a photo, which have names of their own.
	let fileName: String?
	let pageCount: Int?
	let startedAt: Date
}

/// Where one arrival stands, from Save to its filed document.
nonisolated enum ArrivalStage: Equatable {
	case preparing
	/// Queued, and no byte has left the iPhone yet.
	case waiting
	case sending(fraction: Double)
	case retrying(nextAttempt: Date)
	/// The archive took the bytes, and the copy does not hold the document yet.
	case sent
	case reading(IngestionStage)
	case filed(DocumentRowPresentation)
	/// The archive held these bytes already. The row shows that document once the copy holds it filed.
	case alreadyHeld(DocumentRowPresentation?)
	case notAccepted(reason: String)
	case tokenRefused
	case failed(FailureReason, title: String?)
}

/// One row of the Arriving section: what a person sent and where it stands.
nonisolated struct Arrival: Equatable, Identifiable {
	let id: UUID
	/// "Scan", "Photo", or the file's name without its extension.
	let displayName: String
	/// "3 pages · 09:12" for a scan, "1.2 MB · 09:12" for anything else.
	let facts: String
	let stage: ArrivalStage
	/// The document a tap opens, once the archive named it.
	let document: DocumentIdentifier?
}

/// What the trailing edge of a row shows.
nonisolated enum RowTrailing: Equatable {
	case absent
	case activity
	case progress(Double)
	/// The archive holds the document. `filed` once the copy holds it classified.
	case done(filed: Bool)
	case attention
}

/// Resolves arrivals from the queue and the copy, and says what their rows show. Pure, so each
/// stage is tested on its own.
nonisolated enum ArrivalPresentation {
	static func arrival(_ preparing: PreparingSubmission, context: WordingContext) -> Arrival {
		Arrival(
			id: preparing.identifier,
			displayName: displayName(origin: preparing.origin, fileName: preparing.fileName),
			facts: facts(pageCount: preparing.pageCount, byteCount: nil, at: preparing.startedAt, context: context),
			stage: .preparing,
			document: nil
		)
	}

	/// `sentFraction` is what the upload under way has sent, and `document` what the copy holds of
	/// the archived document, nil while it holds nothing.
	static func arrival(
		_ entry: SubmissionEntry,
		sentFraction: Double?,
		document: DocumentDetail?,
		context: WordingContext
	) -> Arrival {
		let manifest = entry.manifest
		let stage: ArrivalStage
		var opened: DocumentIdentifier?
		switch entry.answer {
		case nil, .unavailable:
			if let sentFraction, sentFraction > 0 {
				stage = .sending(fraction: min(sentFraction, 1))
			} else if case let .unavailable(attempts, answeredAt)? = entry.answer {
				let record = SubmissionAnswerRecord.unavailable(attempts: attempts, answeredAt: answeredAt)
				stage = .retrying(nextAttempt: record.nextAttempt ?? answeredAt)
			} else {
				stage = .waiting
			}
		case let .rejected(reason, _):
			stage = .notAccepted(reason: reason)
		case .refusedToken:
			stage = .tokenRefused
		case let .archived(identifier, alreadyHeld, _):
			opened = DocumentIdentifier(value: identifier)
			stage = archivedStage(alreadyHeld: alreadyHeld, document: document, context: context)
		}
		return Arrival(
			id: manifest.identifier,
			displayName: displayName(origin: manifest.origin, fileName: manifest.fileName),
			facts: facts(
				pageCount: manifest.pageCount,
				byteCount: manifest.byteCount,
				at: manifest.createdAt,
				context: context
			),
			stage: stage,
			document: opened
		)
	}

	private static func archivedStage(
		alreadyHeld: Bool,
		document: DocumentDetail?,
		context: WordingContext
	) -> ArrivalStage {
		guard let document else {
			return alreadyHeld ? .alreadyHeld(nil) : .sent
		}
		switch document.condition {
		case let .inIngestion(stage):
			return alreadyHeld ? .alreadyHeld(nil) : .reading(stage)
		case .archived:
			let row = documentRow(document, context: context)
			return alreadyHeld ? .alreadyHeld(row) : .filed(row)
		case let .failed(reason):
			return .failed(reason, title: document.title.flatMap { $0.isEmpty ? nil : $0 })
		}
	}

	/// What the row of `arrival` shows, in the same shape as a document's row, so the picture and
	/// the text stay in place when it becomes the document.
	static func row(_ arrival: Arrival, context: WordingContext) -> DocumentRowPresentation {
		let (thirdLine, tone): (String, DocumentRowThirdLineTone) = switch arrival.stage {
		case .preparing: ("Preparing", .secondary)
		case .waiting: ("Waiting to send", .secondary)
		case .sending: ("Sending", .secondary)
		case let .retrying(nextAttempt):
			(
				"Waiting for the archive. Trying again at \(DocumentFormatting.clockTime(nextAttempt, context: context)).",
				.secondary
			)
		case .sent: ("Sent", .accent)
		case let .reading(stage): (LibraryFailureWording.stageText(stage), .accent)
		case .filed: ("", .secondary)
		case .alreadyHeld: ("Already in the archive", .secondary)
		case let .notAccepted(reason): ("Not accepted. \(sentence(reason))", .failure)
		case .tokenRefused: ("The archive refused the token.", .failure)
		case let .failed(reason, _): (LibraryFailureWording.failureText(reason), .failure)
		}
		switch arrival.stage {
		case let .filed(document), let .alreadyHeld(document?):
			return DocumentRowPresentation(
				title: document.title,
				sender: document.sender,
				dateText: document.dateText,
				amountText: document.amountText,
				thirdLineText: thirdLine,
				thirdLineTone: tone,
				contentKnown: true
			)
		case let .failed(_, title?):
			return plainRow(title: title, arrival.facts, thirdLine, tone)
		default:
			return plainRow(title: arrival.displayName, arrival.facts, thirdLine, tone)
		}
	}

	static func trailing(_ stage: ArrivalStage) -> RowTrailing {
		switch stage {
		case .preparing: .activity
		case .waiting, .retrying, .alreadyHeld: .absent
		case let .sending(fraction): .progress(fraction)
		case .sent, .reading: .done(filed: false)
		case .filed: .done(filed: true)
		case .notAccepted, .tokenRefused, .failed: .attention
		}
	}

	/// What VoiceOver reads as the row's value: the stage, with the share sent while it sends.
	static func spokenStage(_ arrival: Arrival, context: WordingContext) -> String {
		switch arrival.stage {
		case let .sending(fraction):
			"Sending, \(Int((fraction * 100).rounded())) per cent"
		case .filed:
			"Archived"
		default:
			row(arrival, context: context).thirdLineText
		}
	}

	private static func plainRow(
		title: String,
		_ facts: String,
		_ thirdLine: String,
		_ tone: DocumentRowThirdLineTone
	) -> DocumentRowPresentation {
		DocumentRowPresentation(
			title: title,
			sender: facts,
			dateText: nil,
			amountText: nil,
			thirdLineText: thirdLine,
			thirdLineTone: tone,
			contentKnown: false
		)
	}

	/// The archive names a scan's file by its time, so a scan is "Scan", and the name of a photo
	/// from the library says nothing a person chose.
	private static func displayName(origin: SubmissionOrigin, fileName: String?) -> String {
		switch origin {
		case .scan:
			"Scan"
		case .importedPhoto:
			"Photo"
		case .importedFile, .share:
			fileName.map { URL(filePath: $0).deletingPathExtension().lastPathComponent } ?? "Document"
		}
	}

	private static func facts(pageCount: Int?, byteCount: UInt64?, at time: Date, context: WordingContext) -> String {
		let measure = pageCount.map { DocumentFormatting.countText(UInt64($0), singular: "page") }
			?? byteCount.map(DocumentFormatting.byteSize)
		return [measure, DocumentFormatting.clockTime(time, context: context)]
			.compactMap(\.self)
			.joined(separator: " · ")
	}

	/// The archive's reason as a sentence, which some of its reasons lack the full stop of.
	private static func sentence(_ reason: String) -> String {
		let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.hasSuffix(".") ? trimmed : "\(trimmed)."
	}

	/// The row of a filed document, from the detail the copy holds.
	private static func documentRow(_ document: DocumentDetail, context: WordingContext) -> DocumentRowPresentation {
		let currency = document.fields.first { $0.key == "currency" }.flatMap { field -> String? in
			if case let .text(text) = field.value {
				text
			} else {
				nil
			}
		}
		let amount = document.fields.first { $0.key == "amount" }.flatMap { field -> String? in
			if case let .number(decimalText) = field.value {
				DocumentFormatting.decimalAmount(decimalText, currency: currency)
			} else {
				nil
			}
		}
		return DocumentRowPresentation(
			title: document.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Document",
			sender: document.sender?.name ?? "",
			dateText: document.documentDate.map { DocumentFormatting.calendarDate($0, context: context) },
			amountText: amount,
			thirdLineText: "",
			thirdLineTone: .secondary,
			contentKnown: true
		)
	}
}
