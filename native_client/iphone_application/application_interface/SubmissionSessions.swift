import ApplicationBindings
import Foundation
import SubmissionQueue

/// The URL sessions that upload submissions in this process: the application's own, which sends,
/// and the share extension's, which the application holds only to receive its events. Each answer
/// is recorded in the queue on the session's queue, before the session reports its events
/// delivered, so none is lost when the process is suspended after the system's completion handler.
final class SubmissionSessions {
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

	private let configurations: ApplicationEnvironment.TransferSessions
	private let queue: SubmissionQueue
	/// Receives the answer recorded for a submission, nil when it could not be recorded.
	private let received: (SubmissionAnswerRecord?, UUID) -> Void
	private let progressed: (UUID, Double) -> Void
	private var sending: SubmissionTransfer?
	private var attached = AttachedSession.absent

	/// Opens the application's session, which delivers the answers that arrived while the
	/// application was not running as soon as it is created.
	init(
		configurations: ApplicationEnvironment.TransferSessions,
		queue: SubmissionQueue,
		received: @escaping (SubmissionAnswerRecord?, UUID) -> Void,
		progressed: @escaping (UUID, Double) -> Void
	) {
		self.configurations = configurations
		self.queue = queue
		self.received = received
		self.progressed = progressed
		sending = transfer(configuration: configurations.sendingConfiguration)
	}

	func send(_ attempt: SubmissionAttempt, request: DocumentSubmissionRequest, body: URL) {
		sending?.send(attempt, request: request, body: body)
	}

	/// The submissions whose uploads the application's session holds.
	func submissionsInFlight() async -> Set<UUID> {
		await sending?.submissionsInFlight() ?? []
	}

	/// Stops the upload of a submission in either session.
	func cancel(_ identifier: UUID) async {
		for transfer in [sending, attached.transfer].compactMap(\.self) {
			await transfer.cancel(identifier)
		}
	}

	/// Receives the events of the session the system launched the application for: its own, or the
	/// share extension's, which it creates for the events alone.
	func handleBackgroundEvents(session identifier: String, completion: @escaping @MainActor () -> Void) {
		if let sending, sending.sessionIdentifier == identifier {
			sending.handleBackgroundEvents(completion: completion)
			return
		}
		guard let configuration = configurations.shareExtensionConfiguration(identifier: identifier) else {
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
				self?.received(recorded, attempt.submission)
			}
		} onProgress: { [weak self] identifier, fraction in
			Task { @MainActor in
				self?.progressed(identifier, fraction)
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
}
