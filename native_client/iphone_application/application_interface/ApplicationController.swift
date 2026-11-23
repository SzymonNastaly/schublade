import ApplicationBindings
import CoreGraphics
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
	/// Ends with whether the core started.
	@ObservationIgnored private var coreStart: Task<Bool, Never>?

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
		guard case let .running(status) = situation else {
			return nil
		}
		return status.archive.configuration?.origin
	}

	/// Whether the connected token may send. A restricted token reads only part of the archive, and
	/// the ingest route refuses it. While the core starts, the record of the last connected archive
	/// answers, so a scan requested from outside the application opens the camera at once.
	var sendingPermitted: Bool {
		switch situation {
		case .starting:
			recordedArchive.map { !$0.restricted } ?? false
		case .failedToStart:
			false
		case let .running(status):
			status.archive.configuration.map { !$0.restricted } ?? false
		}
	}

	func launch() {
		submissions.open(sessions: environment.transferSessions)
		let start = Task {
			do throws(ApplicationStartFailure) {
				try await gateway.start(configuration: environment.applicationConfiguration)
				return true
			} catch {
				situation = .failedToStart(String(describing: error))
				return false
			}
		}
		coreStart = start
		Task {
			guard await start.value else {
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
			let grant = try await gateway.connectArchive(address: address, token: token)
			// The ingest route refuses a restricted token, so the held submissions wait for one that
			// may send. The grant answers before `sendingPermitted`, which waits for the next status.
			if !grant.restricted {
				submissions.tokenAccepted(by: grant.origin)
			}
			return nil
		} catch {
			return ConnectionWording.refusalSentence(error)
		}
	}

	/// Asks the copy to read the archive and waits until it has, or until no read can follow without
	/// the person, as for a refused token. An archive out of reach is waited for, because the network
	/// may return meanwhile, until the background refresh that calls this is cancelled because its
	/// time is up. The wait in Rust ignores the cancellation, so it ends at the next status.
	func refreshLibrary() async -> SynchronizationAnswer {
		guard await coreStart?.value == true else {
			return .withheld
		}
		let requestedAt = Date.now
		gateway.synchronize()
		var revision: UInt64?
		while true {
			guard let status = try? await gateway.libraryStatusAfter(revision) else {
				return .withheld
			}
			switch SynchronizationAnswer.resolve(status, requestedAt: requestedAt) {
			case .synchronized?:
				return .synchronized
			case .withheld?:
				return .withheld
			case .outOfReach?, nil:
				guard !Task.isCancelled else {
					return .outOfReach
				}
				revision = status.revision
			}
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

	/// The person left the application, so what was filed leaves the top of the library.
	func enteredBackground() {
		submissions.removeSettled()
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
				let contentChanged: Bool = if case let .running(previous) = situation {
					previous.contentRevision != status.contentRevision
				} else {
					true
				}
				situation = .running(status)
				if contentChanged {
					submissions.contentChanged()
				}
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
		connection.configuration.map { ConnectedArchive(origin: $0.origin, restricted: $0.restricted) }
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
	/// A PDF named as the scanner names its scans, "Scan 2026-11-23 09.12.pdf", is sent as a scan
	/// with its pages, because the simulator's document camera captures nothing.
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
			let scanned = kind == .pdf && file.lastPathComponent.hasPrefix("Scan ")
			let pages = scanned ? CGPDFDocument(file as CFURL)?.numberOfPages : nil
			try? await submissions.submit(
				document: copy,
				fileName: file.lastPathComponent,
				kind: kind,
				origin: scanned ? .scan : .importedFile,
				pageCount: pages,
				picture: SubmissionPicture.make(from: file, kind: kind)
			)
		}
	}
	#endif
}
