import ApplicationBindings
import Foundation
import Observation
import SubmissionQueue

/// Owns the gateway, the submissions, and the state every screen reads: whether the core started,
/// and the newest library status it published.
@Observable
final class ApplicationController {
	enum Situation: Equatable {
		case starting
		case failedToStart(String)
		case running(LibraryStatus)
	}

	let environment: ApplicationEnvironment
	let gateway: ApplicationGateway
	let submissions: SubmissionCoordinator
	private(set) var situation = Situation.starting

	init(environment: ApplicationEnvironment) {
		self.environment = environment
		gateway = ApplicationGateway()
		submissions = SubmissionCoordinator(
			queue: SubmissionQueue(root: environment.submissionQueueRoot),
			credentials: environment.applicationConfiguration.credentialStorage,
			gateway: gateway
		)
	}

	/// The archive's origin while one is connected.
	var archiveOrigin: String? {
		guard case let .running(status) = situation, case let .configured(origin, _, _, _, _) = status.archive else {
			return nil
		}
		return origin
	}

	func launch() {
		submissions.open(configuration: environment.transferConfiguration)
		Task {
			do throws(ApplicationStartFailure) {
				try await gateway.start(configuration: environment.applicationConfiguration)
			} catch {
				situation = .failedToStart(String(describing: error))
				return
			}
			#if DEBUG
			if let examination = environment.examination {
				Task {
					await examine(examination)
				}
			}
			#endif
			await followLibrary()
		}
	}

	/// Connects the archive at `address` with `token`, and answers the sentence of a refusal.
	func connect(address: String, token: String) async -> String? {
		do throws(ConnectionRefusal) {
			_ = try await gateway.connectArchive(address: address, token: token)
			return nil
		} catch {
			return ConnectionWording.refusalSentence(error)
		}
	}

	/// The application returns to the screen: read the archive, and send what waits.
	func becameActive() {
		gateway.synchronize()
		submissions.resume()
	}

	/// Follows the library's status until the core stops. A newly connected archive sends the
	/// submissions that waited for it.
	private func followLibrary() async {
		var revision: UInt64?
		while true {
			do throws(ApplicationFault) {
				let status = try await gateway.libraryStatusAfter(revision)
				revision = status.revision
				situation = .running(status)
			} catch {
				return
			}
			if submissions.archiveOrigin != archiveOrigin {
				submissions.archiveOrigin = archiveOrigin
				submissions.resume()
			}
		}
	}

	#if DEBUG
	/// Connects the examination's archive and sends a copy of each of its files, as an import would.
	private func examine(_ examination: ApplicationEnvironment.Examination) async {
		_ = await connect(address: examination.address, token: examination.token)
		guard let directory = examination.documents else {
			return
		}
		let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
		for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
			let copy = URL.temporaryDirectory.appending(path: UUID().uuidString)
			guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else {
				continue
			}
			let kind: SubmissionFileKind = file.pathExtension == "jpg" ? .jpeg : .pdf
			try? submissions.submit(document: copy, fileName: file.lastPathComponent, kind: kind, origin: .importedFile)
		}
	}
	#endif
}
