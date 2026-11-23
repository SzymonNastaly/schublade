import ApplicationBindings
import Foundation
import Synchronization

/// Uploads prepared bodies in one `URLSession`, a background session in the application and the
/// share extension, so an upload continues while the process is suspended or ended, and reads each
/// answer in Rust.
/// The session calls its delegate on its own queue, so this class, in a nonisolated module, keeps its
/// state behind a mutex.
public final class SubmissionTransfer: NSObject, URLSessionDataDelegate, Sendable {
	/// The archive's answer to one upload, or nil when none came, such as without a network.
	public typealias AnswerHandler = @Sendable (SubmissionAttempt, DocumentSubmissionAnswer?) -> Void
	/// The fraction of a submission's body sent so far.
	public typealias ProgressHandler = @Sendable (UUID, Double) -> Void
	/// The system's completion handler of one launch of the process for this session's events.
	public typealias BackgroundEventsCompletion = @MainActor @Sendable () -> Void
	/// What the session reports about the launches for its events, from its own queue.
	public typealias SessionEventHandler = @Sendable (SubmissionTransfer, SessionEvent) -> Void

	/// Each event hands its owner the completion handlers this transfer held, because the owner may
	/// have to let the session go before it calls them: the process can be suspended right after.
	public enum SessionEvent: Sendable {
		/// The session delivered the events of the launches whose handlers it held.
		case eventsDelivered([BackgroundEventsCompletion])
		/// The session ended after `invalidate()` and holds nothing any more.
		case ended([BackgroundEventsCompletion])
	}

	private struct State {
		/// Nil once the session ended.
		var session: URLSession?
		/// Set by `invalidate()`, after which the session accepts no task: URLSession raises an
		/// exception for a task added to an invalidated session.
		var invalidating = false
		var answerBodies: [Int: Data] = [:]
		var backgroundEventsCompletions: [BackgroundEventsCompletion]
	}

	private let state: Mutex<State>
	/// The background session's identifier, nil for a session that ends with the process.
	public let sessionIdentifier: String?
	private let onAnswer: AnswerHandler
	private let onProgress: ProgressHandler
	private let onSessionEvent: SessionEventHandler

	/// `configuration` is a background configuration in the application, and the default one in a
	/// test, where a background session cannot deliver its events to the test process. A session
	/// created for a launch for its events receives that launch's completion handler here, before
	/// the session exists, because the session may deliver every event before this returns.
	public init(
		configuration: URLSessionConfiguration,
		backgroundEventsCompletion: BackgroundEventsCompletion? = nil,
		onAnswer: @escaping AnswerHandler,
		onProgress: @escaping ProgressHandler,
		onSessionEvent: @escaping SessionEventHandler
	) {
		sessionIdentifier = configuration.identifier
		state = Mutex(State(backgroundEventsCompletions: backgroundEventsCompletion.map { [$0] } ?? []))
		self.onAnswer = onAnswer
		self.onProgress = onProgress
		self.onSessionEvent = onSessionEvent
		super.init()
		let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
		state.withLock { $0.session = session }
	}

	/// A background configuration whose uploads continue without the process that started them. Its
	/// files lie in the App Group's container, which the session can read only when it names the group.
	public static func backgroundConfiguration(
		identifier: String,
		sharedContainer: String
	) -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
		configuration.sharedContainerIdentifier = sharedContainer
		configuration.sessionSendsLaunchEvents = true
		configuration.isDiscretionary = false
		return configuration
	}

	/// Starts the upload of a prepared body.
	public func send(_ attempt: SubmissionAttempt, request prepared: DocumentSubmissionRequest, body: URL) {
		guard let url = URL(string: prepared.url) else {
			onAnswer(attempt, nil)
			return
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue(prepared.contentType, forHTTPHeaderField: "Content-Type")
		request.setValue(prepared.authorization, forHTTPHeaderField: "Authorization")
		guard let session = state.withLock({ $0.invalidating ? nil : $0.session }) else {
			onAnswer(attempt, nil)
			return
		}
		let task = session.uploadTask(with: request, fromFile: body)
		task.taskDescription = attempt.taskDescription
		task.resume()
	}

	/// The submissions whose upload is under way in this session.
	public func submissionsInFlight() async -> Set<UUID> {
		guard let session = state.withLock({ $0.session }) else {
			return []
		}
		let tasks = await session.allTasks
		return Set(tasks.compactMap { task in SubmissionAttempt(taskDescription: task.taskDescription)?.submission })
	}

	public func cancel(_ identifier: UUID) async {
		guard let session = state.withLock({ $0.session }) else {
			return
		}
		let tasks = await session.allTasks
		for task in tasks where SubmissionAttempt(taskDescription: task.taskDescription)?.submission == identifier {
			task.cancel()
		}
	}

	/// Holds the system's completion handler of another launch for this session's events until the
	/// session reports them delivered or ends. Answers false when the session ended already, which
	/// then holds nothing.
	@discardableResult
	public func handleBackgroundEvents(completion: @escaping BackgroundEventsCompletion) -> Bool {
		state.withLock { state in
			guard state.session != nil else {
				return false
			}
			state.backgroundEventsCompletions.append(completion)
			return true
		}
	}

	/// Lets the session go once its tasks end, so that another process may create it. Until then it
	/// delivers the answers of those tasks, and then it reports `ended`.
	public func invalidate() {
		state.withLock { state in
			state.invalidating = true
			return state.session
		}?.finishTasksAndInvalidate()
	}

	public func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		state.withLock { $0.answerBodies[dataTask.taskIdentifier, default: Data()].append(data) }
	}

	public func urlSession(
		_: URLSession,
		task: URLSessionTask,
		didSendBodyData _: Int64,
		totalBytesSent: Int64,
		totalBytesExpectedToSend: Int64
	) {
		guard let attempt = SubmissionAttempt(taskDescription: task.taskDescription),
		      totalBytesExpectedToSend > 0
		else {
			return
		}
		onProgress(attempt.submission, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
	}

	public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
		let body = state.withLock { $0.answerBodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
		guard let attempt = SubmissionAttempt(taskDescription: task.taskDescription) else {
			return
		}
		if let error = error as? URLError, error.code == .cancelled {
			return
		}
		guard error == nil, let response = task.response as? HTTPURLResponse else {
			onAnswer(attempt, nil)
			return
		}
		onAnswer(attempt, readDocumentSubmissionAnswer(status: UInt16(response.statusCode), body: body))
	}

	public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
		let completions = state.withLock { state in
			defer { state.backgroundEventsCompletions = [] }
			return state.backgroundEventsCompletions
		}
		onSessionEvent(self, .eventsDelivered(completions))
	}

	public func urlSession(_: URLSession, didBecomeInvalidWithError _: (any Error)?) {
		let completions = state.withLock { state in
			defer {
				state.session = nil
				state.backgroundEventsCompletions = []
			}
			return state.backgroundEventsCompletions
		}
		onSessionEvent(self, .ended(completions))
	}
}
