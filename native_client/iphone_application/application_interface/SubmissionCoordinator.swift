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
	private(set) var entries: [SubmissionEntry] = []
	private(set) var progress: [UUID: Double] = [:]

	private let queue: SubmissionQueue
	private let credentials: CredentialStorage
	private let gateway: ApplicationGateway
	@ObservationIgnored private var sessions: ApplicationEnvironment.TransferSessions?
	/// The application's own session, which sends.
	@ObservationIgnored private var sending: SubmissionTransfer?
	/// The share extension's session while the system delivers its answers to the application.
	/// One process at a time may use a background session, so the application lets it go once they
	/// are delivered, and a later share can upload in it.
	@ObservationIgnored private var attached: SubmissionTransfer?
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
		let attached = attached ?? transfer(configuration: configuration)
		self.attached = attached
		attached.handleBackgroundEvents { @MainActor [weak self] in
			completion()
			attached.invalidate()
			if self?.attached === attached {
				self?.attached = nil
			}
		}
	}

	private func transfer(configuration: URLSessionConfiguration) -> SubmissionTransfer {
		SubmissionTransfer(configuration: configuration) { [weak self] identifier, answer in
			Task { @MainActor in
				self?.received(answer, for: identifier)
			}
		} onProgress: { [weak self] identifier, fraction in
			Task { @MainActor in
				self?.progress[identifier] = fraction
			}
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
			for transfer in [sending, attached].compactMap(\.self) {
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
			case let .prepared(request, body):
				sending.send(entry.id, request: request, body: body)
			case let .answered(answer):
				inFlight.remove(entry.id)
				record(answer, for: entry.id)
			}
		}
	}

	private func received(_ answer: DocumentSubmissionAnswer?, for identifier: UUID) {
		inFlight.remove(identifier)
		progress[identifier] = nil
		let recorded = try? queue.receive(answer, for: identifier)
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
