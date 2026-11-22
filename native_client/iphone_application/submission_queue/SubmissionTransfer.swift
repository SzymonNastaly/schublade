import ApplicationBindings
import Foundation
import Synchronization

/// Uploads prepared bodies in one `URLSession`, a background session in the application and the
/// share extension, so an upload continues while the process is suspended or ended, and reads each
/// answer in Rust.
/// The session calls its delegate on its own queue, so this class, in a nonisolated module, keeps its
/// state behind a mutex.
public final class SubmissionTransfer: NSObject, URLSessionDataDelegate, Sendable {
	/// The archive's answer to a submission, or nil when none came, such as without a network.
	public typealias AnswerHandler = @Sendable (UUID, DocumentSubmissionAnswer?) -> Void
	/// The fraction of a submission's body sent so far.
	public typealias ProgressHandler = @Sendable (UUID, Double) -> Void

	private struct State {
		var session: URLSession?
		var answerBodies: [Int: Data] = [:]
		var backgroundEventsCompletion: (@MainActor @Sendable () -> Void)?
	}

	private let state = Mutex(State())
	/// The background session's identifier, nil for a session that ends with the process.
	public let sessionIdentifier: String?
	private let onAnswer: AnswerHandler
	private let onProgress: ProgressHandler

	/// `configuration` is a background configuration in the application, and the default one in a
	/// test, where a background session cannot deliver its events to the test process.
	public init(
		configuration: URLSessionConfiguration,
		onAnswer: @escaping AnswerHandler,
		onProgress: @escaping ProgressHandler
	) {
		sessionIdentifier = configuration.identifier
		self.onAnswer = onAnswer
		self.onProgress = onProgress
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
	public func send(_ identifier: UUID, request prepared: DocumentSubmissionRequest, body: URL) {
		guard let url = URL(string: prepared.url) else {
			onAnswer(identifier, nil)
			return
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue(prepared.contentType, forHTTPHeaderField: "Content-Type")
		request.setValue(prepared.authorization, forHTTPHeaderField: "Authorization")
		guard let session = state.withLock({ $0.session }) else {
			return
		}
		let task = session.uploadTask(with: request, fromFile: body)
		task.taskDescription = identifier.uuidString
		task.resume()
	}

	/// The submissions whose upload is under way in this session.
	public func submissionsInFlight() async -> Set<UUID> {
		guard let session = state.withLock({ $0.session }) else {
			return []
		}
		let tasks = await session.allTasks
		return Set(tasks.compactMap { task in task.taskDescription.flatMap(UUID.init(uuidString:)) })
	}

	public func cancel(_ identifier: UUID) async {
		guard let session = state.withLock({ $0.session }) else {
			return
		}
		for task in await session.allTasks where task.taskDescription == identifier.uuidString {
			task.cancel()
		}
	}

	/// Holds the system's completion handler of a launch for this session's events, which the
	/// session calls once it delivered them.
	public func handleBackgroundEvents(completion: @escaping @MainActor @Sendable () -> Void) {
		state.withLock { $0.backgroundEventsCompletion = completion }
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
		guard let identifier = task.taskDescription.flatMap(UUID.init(uuidString:)), totalBytesExpectedToSend > 0 else {
			return
		}
		onProgress(identifier, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
	}

	public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
		let body = state.withLock { $0.answerBodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
		guard let identifier = task.taskDescription.flatMap(UUID.init(uuidString:)) else {
			return
		}
		if let error = error as? URLError, error.code == .cancelled {
			return
		}
		guard error == nil, let response = task.response as? HTTPURLResponse else {
			onAnswer(identifier, nil)
			return
		}
		onAnswer(identifier, readDocumentSubmissionAnswer(status: UInt16(response.statusCode), body: body))
	}

	public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
		let completion = state.withLock { state in
			defer { state.backgroundEventsCompletion = nil }
			return state.backgroundEventsCompletion
		}
		Task { @MainActor in
			completion?()
		}
	}
}
