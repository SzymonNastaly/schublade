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
	/// What the share extension last read about the connected archive.
	@ObservationIgnored private var recordedArchive: ConnectedArchive?
	/// Whether the application is on the screen, which the core learns once it started too.
	@ObservationIgnored private var attended = false

	init(environment: ApplicationEnvironment) {
		self.environment = environment
		gateway = ApplicationGateway()
		submissions = SubmissionCoordinator(
			queue: environment.sharedContainer.submissionQueue,
			credentials: environment.applicationConfiguration.credentialStorage,
			gateway: gateway
		)
		recordedArchive = environment.sharedContainer.connectedArchive()
	}

	/// The archive's origin while one is connected.
	var archiveOrigin: String? {
		guard case let .running(status) = situation, case let .configured(origin, _, _, _, _) = status.archive else {
			return nil
		}
		return origin
	}

	/// Whether the connected token may send. A restricted token reads only part of the archive, and
	/// the ingest route refuses it.
	var sendingPermitted: Bool {
		guard case let .running(status) = situation,
		      case let .configured(_, _, _, _, restricted) = status.archive
		else {
			return false
		}
		return !restricted
	}

	func launch() {
		submissions.open(sessions: environment.transferSessions)
		Task {
			do throws(ApplicationStartFailure) {
				try await gateway.start(configuration: environment.applicationConfiguration)
			} catch {
				situation = .failedToStart(String(describing: error))
				return
			}
			gateway.interfaceAttended(attended)
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

	func becameActive() {
		attended = true
		gateway.interfaceAttended(true)
		submissions.resume()
	}

	func resignedActive() {
		attended = false
		gateway.interfaceAttended(false)
	}

	/// Follows the library's status until the core stops. A newly connected archive sends the
	/// submissions that waited for it, and the share extension learns of every change of the archive
	/// or of its restriction.
	private func followLibrary() async {
		var revision: UInt64?
		while true {
			do throws(ApplicationFault) {
				let status = try await gateway.libraryStatusAfter(revision)
				revision = status.revision
				situation = .running(status)
				record(Self.connectedArchive(status.archive))
			} catch {
				return
			}
			if submissions.archiveOrigin != archiveOrigin {
				submissions.archiveOrigin = archiveOrigin
				submissions.resume()
			}
		}
	}

	private static func connectedArchive(_ connection: ArchiveConnection) -> ConnectedArchive? {
		switch connection {
		case .notConfigured:
			nil
		case let .configured(origin, _, _, _, restricted):
			ConnectedArchive(origin: origin, restricted: restricted)
		}
	}

	/// The next status tries again after a failure, and until then the share extension reads the
	/// previous record.
	private func record(_ archive: ConnectedArchive?) {
		guard archive != recordedArchive, (try? writeRecord(of: archive)) != nil else {
			return
		}
		recordedArchive = archive
	}

	/// Writes the record to a temporary file and renames it, so the share extension never reads half
	/// of one, or removes it while no archive is connected.
	private func writeRecord(of archive: ConnectedArchive?) throws {
		let file = environment.sharedContainer.connectedArchiveFile
		guard let archive else {
			if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
				try FileManager.default.removeItem(at: file)
			}
			return
		}
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try JSONEncoder().encode(archive).write(to: file, options: .atomic)
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
