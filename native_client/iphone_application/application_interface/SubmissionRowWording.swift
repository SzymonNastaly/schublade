import Foundation
import LibraryPresentation
import SubmissionQueue

/// What a row of the Sending list says about one submission.
nonisolated enum SubmissionRowWording {
	enum Tone: Equatable {
		case waiting
		case archived
		case attention
	}

	struct RowContent: Equatable {
		let title: String
		let status: String
		let symbol: String
		let tone: Tone
	}

	static func row(_ entry: SubmissionEntry, sentFraction: Double?, now: Date = .now) -> RowContent {
		let manifest = entry.manifest
		let symbol = switch manifest.origin {
		case .scan: "doc.viewfinder"
		case .importedPhoto: "photo"
		case .importedFile, .share: "doc"
		}
		let (status, tone) = statusSentence(entry.answer, sentFraction: sentFraction)
		let pages = manifest.pageCount.map { DocumentFormatting.countText(UInt64($0), singular: "page") }
		let created = manifest.createdAt.formatted(date: .omitted, time: .shortened)
		let detail = [pages, created].compactMap(\.self).joined(separator: " · ")
		return RowContent(title: manifest.fileName, status: "\(status)\n\(detail)", symbol: symbol, tone: tone)
	}

	private static func statusSentence(_ answer: SubmissionAnswerRecord?, sentFraction: Double?) -> (String, Tone) {
		switch answer {
		case nil:
			guard let sentFraction else {
				return ("Waiting to send", .waiting)
			}
			return ("Sending · \(Int((sentFraction * 100).rounded())) %", .waiting)
		case let .archived(_, alreadyHeld, _):
			return (alreadyHeld ? "Already in the archive" : "In the archive", .archived)
		case let .rejected(reason, _):
			return ("Not accepted: \(reason)", .attention)
		case .refusedToken:
			return ("The archive refused the token. Connect again to send.", .attention)
		case let .unavailable(attempts, answeredAt):
			let next = SubmissionAnswerRecord.unavailable(attempts: attempts, answeredAt: answeredAt).nextAttempt
				?? answeredAt
			return (
				"Waiting for the archive · trying again at \(next.formatted(date: .omitted, time: .shortened))",
				.waiting
			)
		}
	}
}
