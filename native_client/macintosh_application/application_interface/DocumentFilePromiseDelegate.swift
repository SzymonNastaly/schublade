import AppKit
import ApplicationBindings
import ApplicationPresentation
import os

/// Supplies promised document originals for drag-and-drop exports on a background queue.
nonisolated class DocumentFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
	private static let transferQueue: OperationQueue = {
		let queue = OperationQueue()
		queue.name = "org.schublade.filePromise"
		queue.maxConcurrentOperationCount = 4
		queue.qualityOfService = .userInitiated
		return queue
	}()

	typealias FetchOriginalPath =
		@MainActor @Sendable (DocumentIdentifier) async throws(RepresentationRefusal) -> String

	private let document: DocumentIdentifier
	private let fileName: String
	private let fetchOriginalPath: FetchOriginalPath
	private let reportFailure: @MainActor @Sendable (RepresentationRefusal) -> Void

	init(
		document: DocumentIdentifier,
		fileName: String,
		fetchOriginalPath: @escaping FetchOriginalPath,
		reportFailure: @escaping @MainActor @Sendable (RepresentationRefusal) -> Void
	) {
		self.document = document
		self.fileName = fileName
		self.fetchOriginalPath = fetchOriginalPath
		self.reportFailure = reportFailure
	}

	func filePromiseProvider(_: NSFilePromiseProvider, fileNameForType _: String) -> String {
		fileName
	}

	func operationQueue(for _: NSFilePromiseProvider) -> OperationQueue {
		Self.transferQueue
	}

	func filePromiseProvider(
		_: NSFilePromiseProvider,
		writePromiseTo url: URL,
		completionHandler: @escaping (Error?) -> Void
	) {
		let semaphore = DispatchSemaphore(value: 0)
		let outcome = OSAllocatedUnfairLock<Result<Void, any Error>?>(initialState: nil)
		let document = document
		let fetchOriginalPath = fetchOriginalPath
		let reportFailure = reportFailure

		Task {
			let result: Result<Void, any Error>
			do {
				let sourcePath = try await fetchOriginalPath(document)
				try OriginalFileCopy.write(from: URL(fileURLWithPath: sourcePath), to: url)
				result = .success(())
			} catch let refusal as RepresentationRefusal {
				await reportFailure(refusal)
				result = .failure(refusal)
			} catch {
				result = .failure(error)
			}
			outcome.withLock { $0 = result }
			semaphore.signal()
		}

		semaphore.wait()
		let finalResult = outcome.withLock { $0 }
		switch finalResult {
		case .success:
			completionHandler(nil)
		case let .failure(error):
			completionHandler(error)
		case nil:
			completionHandler(CocoaError(.fileWriteUnknown))
		}
	}
}
