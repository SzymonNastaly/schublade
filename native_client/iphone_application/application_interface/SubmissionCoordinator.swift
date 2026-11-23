import ApplicationBindings
import Foundation
import Observation
import SubmissionQueue

/// Sends the submissions of the queue and keeps what the Sending list shows: every submission with
/// its answer, and the fraction sent of those under way. It prepares a body when it starts an
/// upload, records each answer, sends an unavailable submission again on its schedule, and asks
/// the library to read the archive once a submission is archived.
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

	private(set) var entries: [SubmissionEntry] = []
	private(set) var progress: [UUID: Double] = [:]

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

	/// Moves `document` into the queue and sends it.
	func submit(
		document: URL,
		fileName: String,
		kind: SubmissionFileKind,
		origin: SubmissionOrigin,
		pageCount: Int? = nil
	) throws(SubmissionQueue.QueueFailure) {
		let entry = try queue.enqueue(
			document: document,
			fileName: fileName,
			kind: kind,
			origin: origin,
			pageCount: pageCount
		)
		reload()
		send(entry)
	}

	/// Removes a submission from the list, and stops its upload if one is under way.
	func remove(_ identifier: UUID) {
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
	/// connection is made, and when the next submission falls due.
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

	func documentFile(of entry: SubmissionEntry) -> URL? {
		queue.documentFile(of: entry)
	}

	private func reload() {
		entries = queue.entries()
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

	private func received(_ recorded: SubmissionAnswerRecord?, for identifier: UUID) {
		inFlight.remove(identifier)
		progress[identifier] = nil
		reload()
		switch recorded {
		case .archived?:
			gateway.synchronize()
		case .unavailable?:
			scheduleResumption()
		case .rejected?, .refusedToken?, nil:
			break
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
