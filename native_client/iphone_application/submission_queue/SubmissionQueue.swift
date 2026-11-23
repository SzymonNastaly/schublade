import ApplicationBindings
import Foundation

/// The submissions on this device, one directory each, under a root that the application and its
/// share extension share. A submission is built under `incoming/` and renamed into `submissions/`
/// when complete, so no reader sees half of one, and its answer is written to a temporary name and
/// renamed too. No database and no lock is shared between the two processes.
public struct SubmissionQueue: Sendable {
	public enum QueueFailure: Error, Equatable {
		case documentUnreadable(String)
		case queueUnwritable(String)
	}

	private static let manifestName = "submission.json"
	private static let answerName = "answer.json"
	/// The archived answer, apart from every other, because no later answer may replace it.
	private static let archivedAnswerName = "archived_answer.json"
	private static let bodyName = "request_body"
	/// How long an archived submission stays listed.
	public static let archivedRetention: TimeInterval = 7 * 24 * 3600

	public let root: URL

	public init(root: URL) {
		self.root = root
	}

	private var submissions: URL {
		root.appending(path: "submissions", directoryHint: .isDirectory)
	}

	private var incoming: URL {
		root.appending(path: "incoming", directoryHint: .isDirectory)
	}

	private func directory(of identifier: UUID) -> URL {
		submissions.appending(path: identifier.uuidString, directoryHint: .isDirectory)
	}

	/// Moves `document` into a new submission, which then owns the file. The share extension claims
	/// the upload at `now`, before the rename, so the application never sees its submission unclaimed.
	public func enqueue(
		document: URL,
		fileName: String,
		kind: SubmissionFileKind,
		origin: SubmissionOrigin,
		pageCount: Int? = nil,
		claimingUpload: Bool = false,
		now: Date = .now
	) throws(QueueFailure) -> SubmissionEntry {
		let identifier = UUID()
		let building = incoming.appending(path: identifier.uuidString, directoryHint: .isDirectory)
		let manifest: SubmissionManifest
		do {
			try FileManager.default.createDirectory(at: building, withIntermediateDirectories: true)
			let documentFile = building.appending(path: "document.\(kind.fileExtension)")
			try FileManager.default.moveItem(at: document, to: documentFile)
			let byteCount = try documentFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
			manifest = SubmissionManifest(
				identifier: identifier,
				origin: origin,
				fileName: fileName,
				kind: kind,
				byteCount: UInt64(byteCount),
				pageCount: pageCount,
				createdAt: now,
				uploadClaimedAt: claimingUpload ? now : nil
			)
			try JSONEncoder().encode(manifest).write(to: building.appending(path: Self.manifestName))
		} catch {
			try? FileManager.default.removeItem(at: building)
			throw .documentUnreadable(error.localizedDescription)
		}
		do {
			try FileManager.default.createDirectory(at: submissions, withIntermediateDirectories: true)
			try FileManager.default.moveItem(at: building, to: directory(of: identifier))
		} catch {
			try? FileManager.default.removeItem(at: building)
			throw .queueUnwritable(error.localizedDescription)
		}
		return SubmissionEntry(manifest: manifest, answer: nil)
	}

	/// Every complete submission, newest first. A directory whose manifest cannot be read is skipped.
	public func entries() -> [SubmissionEntry] {
		let directories = (try? FileManager.default.contentsOfDirectory(
			at: submissions,
			includingPropertiesForKeys: nil
		)) ?? []
		return directories.compactMap(Self.entry(in:))
			.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
	}

	/// One complete submission, or nil when none has this identifier, as after a person removed it.
	public func entry(_ identifier: UUID) -> SubmissionEntry? {
		Self.entry(in: directory(of: identifier))
	}

	private static func entry(in directory: URL) -> SubmissionEntry? {
		guard let data = try? Data(contentsOf: directory.appending(path: manifestName)),
		      let manifest = try? JSONDecoder().decode(SubmissionManifest.self, from: data)
		else {
			return nil
		}
		let answer = [archivedAnswerName, answerName].lazy
			.compactMap { name in
				(try? Data(contentsOf: directory.appending(path: name)))
					.flatMap { try? JSONDecoder().decode(SubmissionAnswerRecord.self, from: $0) }
			}
			.first
		return SubmissionEntry(manifest: manifest, answer: answer)
	}

	/// The file whose bytes are sent, while the submission still holds them.
	public func documentFile(of entry: SubmissionEntry) -> URL? {
		let file = directory(of: entry.id).appending(path: "document.\(entry.manifest.kind.fileExtension)")
		return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? file : nil
	}

	/// Where the request's body is written and uploaded from.
	public func bodyFile(of identifier: UUID) -> URL {
		directory(of: identifier).appending(path: Self.bodyName)
	}

	/// Records the archive's answer and answers the one that stands. An archived answer is final,
	/// whichever process records what: it goes into a file of its own, which the queue reads before
	/// any other answer, and the submission gives up its bytes at once, because the archive holds
	/// them. A newly archived answer replaces an archived one, and one that names the document already
	/// held is renamed exclusively, so the second upload of a submission that both processes sent
	/// never hides that the first archived it. Any other answer replaces the one before it by a
	/// rename, and a refused submission keeps its bytes, so a person can still share the file.
	@discardableResult
	public func record(
		_ answer: SubmissionAnswerRecord,
		for identifier: UUID
	) throws(QueueFailure) -> SubmissionAnswerRecord {
		let directory = directory(of: identifier)
		let temporary = directory.appending(path: "\(Self.answerName).\(UUID().uuidString)")
		do {
			try JSONEncoder().encode(answer).write(to: temporary)
		} catch {
			throw .queueUnwritable(error.localizedDescription)
		}
		let temporaryPath = temporary.path(percentEncoded: false)
		let archivedPath = directory.appending(path: Self.archivedAnswerName).path(percentEncoded: false)
		let renamed = switch answer {
		case .archived(_, alreadyHeld: false, _):
			rename(temporaryPath, archivedPath)
		case .archived(_, alreadyHeld: true, _):
			renamex_np(temporaryPath, archivedPath, UInt32(RENAME_EXCL))
		case .rejected, .refusedToken, .unavailable:
			rename(temporaryPath, directory.appending(path: Self.answerName).path(percentEncoded: false))
		}
		if renamed != 0 {
			let failure = errno
			try? FileManager.default.removeItem(at: temporary)
			guard failure == EEXIST else {
				throw .queueUnwritable(String(cString: strerror(failure)))
			}
		}
		try? FileManager.default.removeItem(at: bodyFile(of: identifier))
		guard let entry = entry(identifier) else {
			return answer
		}
		if case .archived = entry.answer, let document = documentFile(of: entry) {
			try? FileManager.default.removeItem(at: document)
		}
		return entry.answer ?? answer
	}

	/// Records the archive's answer to a submission, or the lack of one, whichever process the
	/// upload's session delivered it to. Answers nil when the submission is gone.
	@discardableResult
	public func receive(
		_ answer: DocumentSubmissionAnswer?,
		for identifier: UUID
	) throws(QueueFailure) -> SubmissionAnswerRecord? {
		guard let entry = entry(identifier) else {
			return nil
		}
		return try record(SubmissionAnswerRecord(answer: answer, previous: entry.answer), for: identifier)
	}

	public func remove(_ identifier: UUID) {
		try? FileManager.default.removeItem(at: directory(of: identifier))
	}

	/// Removes archived submissions older than `archivedRetention`, and half-built ones that a
	/// process left under `incoming/` more than an hour ago.
	public func removeExpired(now: Date = .now) {
		for entry in entries() {
			guard case let .archived(_, _, answeredAt) = entry.answer else {
				continue
			}
			if now.timeIntervalSince(answeredAt) > Self.archivedRetention {
				remove(entry.id)
			}
		}
		let leftovers = (try? FileManager.default.contentsOfDirectory(
			at: incoming,
			includingPropertiesForKeys: [.contentModificationDateKey]
		)) ?? []
		for leftover in leftovers {
			let modified = (try? leftover.resourceValues(forKeys: [.contentModificationDateKey]))?
				.contentModificationDate ?? now
			if now.timeIntervalSince(modified) > 3600 {
				try? FileManager.default.removeItem(at: leftover)
			}
		}
	}
}
