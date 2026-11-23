import ApplicationBindings
import Foundation
import ImageIO
import LibraryPresentation
import Observation
import SubmissionQueue
import UIKit

/// Sends the submissions of the queue and keeps what the Arriving section shows: the documents
/// still being written, every submission with its answer, the fraction sent of those under way, and
/// what the copy holds of each archived one. It prepares a body when it starts an upload, records
/// each answer, sends an unavailable submission again on its schedule, asks the library to read the
/// archive once a submission is archived, and lets a filed submission go when the person leaves.
@Observable
final class SubmissionCoordinator {
	/// The share extension's session in this process. One process at a time may use a background
	/// session, so the application creates it only when the system launches the application for its
	/// events, and lets it go once they are delivered, so that a later share can upload in it.
	private enum AttachedSession {
		/// No session under the extension's identifier exists in this process.
		case absent
		/// The session delivers the events of the launches whose completion handlers it holds.
		case delivering(SubmissionTransfer)
		/// The session finishes the uploads still under way, delivers their answers, and ends. A
		/// launch for its events meanwhile is handed to it, because a second session under the
		/// identifier would receive nothing and would hold the identifier against the next share.
		case invalidating(SubmissionTransfer)

		var transfer: SubmissionTransfer? {
			switch self {
			case .absent: nil
			case let .delivering(transfer), let .invalidating(transfer): transfer
			}
		}
	}

	private(set) var preparing: [PreparingSubmission] = []
	private(set) var entries: [SubmissionEntry] = []
	private(set) var progress: [UUID: Double] = [:]
	/// What the copy holds of each archived submission's document.
	private(set) var documents: [UUID: DocumentDetail] = [:]
	/// The first page of each arrival, drawn for its row.
	@ObservationIgnored private var pictures: [UUID: UIImage] = [:]
	@ObservationIgnored private var documentReading: Task<Void, Never>?
	@ObservationIgnored private var documentsStale = false

	private let queue: SubmissionQueue
	private let credentials: CredentialStorage
	private let gateway: ApplicationGateway
	@ObservationIgnored private var sessions: ApplicationEnvironment.TransferSessions?
	/// The application's own session, which sends.
	@ObservationIgnored private var sending: SubmissionTransfer?
	@ObservationIgnored private var attached = AttachedSession.absent
	@ObservationIgnored private var inFlight: Set<UUID> = []
	@ObservationIgnored private var resumption: Task<Void, Never>?
	/// The archive's origin while one is connected.
	@ObservationIgnored var archiveOrigin: String?

	init(queue: SubmissionQueue, credentials: CredentialStorage, gateway: ApplicationGateway) {
		self.queue = queue
		self.credentials = credentials
		self.gateway = gateway
	}

	/// Opens the application's session, which delivers the answers that arrived while the
	/// application was not running as soon as it is created.
	func open(sessions: ApplicationEnvironment.TransferSessions) {
		self.sessions = sessions
		sending = transfer(configuration: sessions.sendingConfiguration)
		reload()
	}

	/// Receives the events of the session the system launched the application for: its own, or the
	/// share extension's, which it creates for the events alone.
	func handleBackgroundEvents(session identifier: String, completion: @escaping @MainActor () -> Void) {
		if let sending, sending.sessionIdentifier == identifier {
			sending.handleBackgroundEvents(completion: completion)
			return
		}
		guard let configuration = sessions?.shareExtensionConfiguration(identifier: identifier) else {
			completion()
			return
		}
		// A session that ended before its report reached this actor holds nothing, and its
		// identifier is free for a new one.
		if let transfer = attached.transfer, transfer.handleBackgroundEvents(completion: completion) {
			return
		}
		attached = .delivering(transfer(configuration: configuration, backgroundEventsCompletion: completion))
	}

	/// The answers are recorded on the session's queue, before it reports its events delivered, so
	/// none is lost when the process is suspended after the system's completion handler.
	private func transfer(
		configuration: URLSessionConfiguration,
		backgroundEventsCompletion: SubmissionTransfer.BackgroundEventsCompletion? = nil
	) -> SubmissionTransfer {
		SubmissionTransfer(
			configuration: configuration,
			backgroundEventsCompletion: backgroundEventsCompletion
		) { [queue, weak self] attempt, answer in
			let recorded = try? queue.receive(answer, for: attempt)
			Task { @MainActor in
				self?.received(recorded, for: attempt.submission)
			}
		} onProgress: { [weak self] identifier, fraction in
			Task { @MainActor in
				self?.progress[identifier] = fraction
			}
		} onSessionEvent: { [weak self] transfer, event in
			Task { @MainActor in
				self?.reported(event, by: transfer)
			}
		}
	}

	/// Lets the share extension's session go once it delivered its events, and only then calls the
	/// system's completion handlers, because the application may be suspended right after.
	private func reported(_ event: SubmissionTransfer.SessionEvent, by transfer: SubmissionTransfer) {
		switch event {
		case let .eventsDelivered(completions):
			if case let .delivering(attachedTransfer) = attached, attachedTransfer === transfer {
				transfer.invalidate()
				attached = .invalidating(transfer)
			}
			completions.forEach { $0() }
		case let .ended(completions):
			if attached.transfer === transfer {
				attached = .absent
			}
			completions.forEach { $0() }
		}
	}

	/// Removes a submission from the list, and stops its upload if one is under way. A document still
	/// being written loses its row, and its file is deleted once written instead of being sent.
	func remove(_ identifier: UUID) {
		abandon(identifier)
		Task {
			for transfer in [sending, attached.transfer].compactMap(\.self) {
				await transfer.cancel(identifier)
			}
		}
		inFlight.remove(identifier)
		queue.remove(identifier)
		reload()
	}

	/// Starts every submission that is due at `now` and has no upload in the application's session:
	/// an unanswered one, unless the share extension claimed it less than 15 minutes ago, and an
	/// unavailable one whose time has come. Called at launch, on returning to the foreground, when a
	/// connection is made, after every answer, and when the next submission falls due.
	func resume(now: Date = .now) {
		queue.removeExpired(now: now)
		reload()
		Task {
			if let sending {
				await inFlight.formUnion(sending.submissionsInFlight())
			}
			for entry in entries where !inFlight.contains(entry.id) && (entry.sendingDueAt ?? .distantFuture) <= now {
				send(entry)
			}
			scheduleResumption()
		}
	}

	/// The archive at `origin` accepted a token that permits sending, so every submission whose token
	/// was refused is sent again with it at once. A token replaced on the same origin leaves the
	/// library's origin as it was, so nothing else would resume them.
	func tokenAccepted(by origin: String) {
		archiveOrigin = origin
		queue.tokenAccepted()
		resume()
	}

	func documentFile(of entry: SubmissionEntry) -> URL? {
		queue.documentFile(of: entry)
	}

	private func reload() {
		entries = queue.entries()
		let shown = Set(entries.map(\.id) + preparing.map(\.identifier))
		pictures = pictures.filter { shown.contains($0.key) }
		if documents.keys.contains(where: { !shown.contains($0) }) {
			documents = documents.filter { shown.contains($0.key) }
		}
	}

	private func send(_ entry: SubmissionEntry) {
		guard let sending, let archiveOrigin else {
			return
		}
		inFlight.insert(entry.id)
		Task {
			switch await queue.prepare(entry, archiveOrigin: archiveOrigin, credentials: credentials) {
			case let .prepared(request, attempt, body):
				sending.send(attempt, request: request, body: body)
			case let .answered(answer):
				inFlight.remove(entry.id)
				record(answer, for: entry.id)
			}
		}
	}

	/// Resumes after every answer, because the refusal of a token replaced meanwhile makes its
	/// submission due at once, and the acceptance passed over that submission while it was in flight.
	private func received(_ recorded: SubmissionAnswerRecord?, for identifier: UUID) {
		inFlight.remove(identifier)
		progress[identifier] = nil
		resume()
		if case .archived? = recorded {
			gateway.synchronize()
			contentChanged()
		}
	}

	private func record(_ answer: SubmissionAnswerRecord, for identifier: UUID) {
		_ = try? queue.record(answer, for: identifier)
		reload()
	}

	/// Wakes when the next submission falls due. One due already was sent by `resume`, or waits for
	/// a connection, which resumes again.
	private func scheduleResumption() {
		resumption?.cancel()
		let now = Date.now
		guard let next = entries.compactMap(\.sendingDueAt).filter({ $0 > now }).min() else {
			return
		}
		resumption = Task { [weak self] in
			try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 1)))
			guard !Task.isCancelled else {
				return
			}
			self?.resume()
		}
	}
}

/// The Arriving section: the rows of documents still being written, the pictures, and what the
/// copy holds of each archived submission.
extension SubmissionCoordinator {
	/// Every arrival, newest first.
	func arrivals(context: WordingContext) -> [Arrival] {
		let queued = Set(entries.map(\.id))
		let written = preparing.filter { !queued.contains($0.identifier) }
			.map { (time: $0.startedAt, arrival: ArrivalPresentation.arrival($0, context: context)) }
		let sent = entries.map { entry in
			(
				time: entry.manifest.createdAt,
				arrival: ArrivalPresentation.arrival(
					entry,
					sentFraction: progress[entry.id],
					document: documents[entry.id],
					context: context
				)
			)
		}
		return (written + sent).sorted { $0.time > $1.time }.map(\.arrival)
	}

	/// The first page of an arrival, drawn for its row, or nil for one without a picture.
	func picture(of identifier: UUID) -> UIImage? {
		if let picture = pictures[identifier] {
			return picture
		}
		guard let file = queue.pictureFile(of: identifier),
		      let source = CGImageSourceCreateWithURL(file as CFURL, nil),
		      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else {
			return nil
		}
		let picture = RowPicture.framed(decoded)
		pictures[identifier] = picture
		return picture
	}

	/// Shows a row for a document whose file is still being written, as a scan's PDF after Save,
	/// and answers its identifier, which the submission takes once written.
	func prepare(
		origin: SubmissionOrigin,
		fileName: String? = nil,
		pageCount: Int? = nil,
		firstPage: CGImage? = nil,
		startedAt: Date = .now
	) -> UUID {
		let identifier = UUID()
		if let firstPage {
			pictures[identifier] = RowPicture.framed(firstPage)
		}
		preparing.append(PreparingSubmission(
			identifier: identifier,
			origin: origin,
			fileName: fileName,
			pageCount: pageCount,
			startedAt: startedAt
		))
		return identifier
	}

	/// Removes the row of a document that could not be written, and answers whether it still showed,
	/// which it no longer does once the person removed it.
	@discardableResult
	func abandon(_ identifier: UUID) -> Bool {
		pictures[identifier] = nil
		guard let index = preparing.firstIndex(where: { $0.identifier == identifier }) else {
			return false
		}
		preparing.remove(at: index)
		return true
	}

	/// Moves `document` into the queue and sends it. A document prepared under `identifier` keeps
	/// its row and its place, and one whose row the person removed meanwhile is deleted. A document
	/// the queue cannot take keeps its row for the caller to abandon.
	func submit(
		document: URL,
		fileName: String,
		kind: SubmissionFileKind,
		origin: SubmissionOrigin,
		pageCount: Int? = nil,
		picture: CGImage? = nil,
		preparedAs identifier: UUID? = nil
	) throws(SubmissionQueue.QueueFailure) {
		let prepared = preparing.first { $0.identifier == identifier }
		if identifier != nil, prepared == nil {
			try? FileManager.default.removeItem(at: document)
			return
		}
		let entry = try queue.enqueue(
			document: document,
			fileName: fileName,
			kind: kind,
			origin: origin,
			pageCount: pageCount,
			picture: picture,
			identifier: prepared?.identifier ?? UUID(),
			now: prepared?.startedAt ?? .now
		)
		preparing.removeAll { $0.identifier == identifier }
		reload()
		send(entry)
	}

	/// Reads what the copy holds of each archived submission's document, after the copy changed.
	/// A day's submissions are a handful, so these are a few local reads.
	func contentChanged() {
		guard documentReading == nil else {
			documentsStale = true
			return
		}
		documentsStale = false
		let archived = entries.compactMap { entry -> (UUID, DocumentIdentifier)? in
			guard case let .archived(document, _, _)? = entry.answer else {
				return nil
			}
			return (entry.id, DocumentIdentifier(value: document))
		}
		documentReading = Task {
			var read: [UUID: DocumentDetail] = [:]
			for (identifier, document) in archived {
				if let detail = try? await gateway.document(document) {
					read[identifier] = detail
				}
			}
			if read != documents {
				documents = read
			}
			documentReading = nil
			if documentsStale {
				contentChanged()
			}
		}
	}

	/// Lets every submission go whose document the copy holds filed or failed, once the person left
	/// the application, so a finished letter is shown once on top and then only in its month.
	func removeSettled() {
		for entry in entries {
			switch documents[entry.id]?.condition {
			case .archived?, .failed?:
				queue.remove(entry.id)
			case .inIngestion?, nil:
				continue
			}
		}
		reload()
	}
}
