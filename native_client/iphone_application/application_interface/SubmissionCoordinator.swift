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
	/// The application's session, which sends, then the share extension's, whose answers arrive here
	/// once the extension ended.
	@ObservationIgnored private var transfers: [SubmissionTransfer] = []
	@ObservationIgnored private var inFlight: Set<UUID> = []
	@ObservationIgnored private var retry: Task<Void, Never>?
	/// The archive's origin while one is connected.
	@ObservationIgnored var archiveOrigin: String?

	init(queue: SubmissionQueue, credentials: CredentialStorage, gateway: ApplicationGateway) {
		self.queue = queue
		self.credentials = credentials
		self.gateway = gateway
	}

	/// Opens the application's session and attaches to the others. A background session delivers
	/// the answers that arrived while the application was not running as soon as it is created.
	func open(sending: URLSessionConfiguration, attaching: [URLSessionConfiguration]) {
		transfers = ([sending] + attaching).map { configuration in
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
		reload()
	}

	func handleBackgroundEvents(session identifier: String, completion: @escaping @MainActor () -> Void) {
		guard let transfer = transfers.first(where: { $0.sessionIdentifier == identifier }) else {
			completion()
			return
		}
		transfer.handleBackgroundEvents(completion: completion)
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
			for transfer in transfers {
				await transfer.cancel(identifier)
			}
		}
		inFlight.remove(identifier)
		queue.remove(identifier)
		reload()
	}

	/// Starts every submission that waits: unanswered ones without an upload in either session, such
	/// as one the share extension queued but did not start, and unavailable ones whose time has come.
	/// Called at launch, on returning to the foreground, and when a connection is made.
	func resume() {
		queue.removeExpired()
		reload()
		Task {
			for transfer in transfers {
				let underWay = await transfer.submissionsInFlight()
				inFlight.formUnion(underWay)
			}
			let now = Date.now
			for entry in entries where !inFlight.contains(entry.id) {
				switch entry.answer {
				case nil:
					send(entry)
				case let answer? where (answer.nextAttempt ?? .distantFuture) <= now:
					send(entry)
				case .some:
					break
				}
			}
			scheduleRetry()
		}
	}

	func documentFile(of entry: SubmissionEntry) -> URL? {
		queue.documentFile(of: entry)
	}

	private func reload() {
		entries = queue.entries()
	}

	private func send(_ entry: SubmissionEntry) {
		guard let transfer = transfers.first, let archiveOrigin else {
			return
		}
		inFlight.insert(entry.id)
		Task {
			switch await queue.prepare(entry, archiveOrigin: archiveOrigin, credentials: credentials) {
			case let .prepared(request, body):
				transfer.send(entry.id, request: request, body: body)
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
			scheduleRetry()
		case .rejected?, .refusedToken?, nil:
			break
		}
	}

	private func record(_ answer: SubmissionAnswerRecord, for identifier: UUID) {
		try? queue.record(answer, for: identifier)
		reload()
	}

	/// Wakes at the earliest next attempt of an unavailable submission.
	private func scheduleRetry() {
		retry?.cancel()
		guard let next = entries.compactMap(\.answer?.nextAttempt).min() else {
			return
		}
		retry = Task { [weak self] in
			try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 1)))
			guard !Task.isCancelled else {
				return
			}
			self?.resume()
		}
	}
}
