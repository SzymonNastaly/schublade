import ApplicationBindings
import DocumentReading
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
	/// The first page as the JPEG of 480 pixels the archive receives beside the bytes. It stays when
	/// the archive takes them, so the row keeps its picture until the archive's own replaces it.
	private static let pictureName = "thumbnail.jpg"
	/// The text of each page as the archive receives it, absent while the document awaits the
	/// application's recognition.
	private static let pageTextsName = "page_texts.json"
	/// When the archive last accepted a token that permits sending.
	private static let tokenAcceptanceName = "token_accepted.json"
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

	/// Moves `document` into a new submission, which then owns the file, with what was read from it.
	/// Contents that await recognition, or none, leave the reading to `prepare`. The share extension
	/// claims the upload at `now`, before the rename, so the application never sees its submission
	/// unclaimed. `identifier` lets a row shown while the document was prepared stay the same row.
	public func enqueue(
		document: URL,
		fileName: String,
		kind: SubmissionFileKind,
		origin: SubmissionOrigin,
		pageCount: Int? = nil,
		contents: DocumentContents? = nil,
		identifier: UUID = UUID(),
		claimingUpload: Bool = false,
		now: Date = .now
	) throws(QueueFailure) -> SubmissionEntry {
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
			if let contents {
				try Self.write(contents, into: building)
			}
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

	/// The picture of the first page, for a submission enqueued with one.
	public func pictureFile(of identifier: UUID) -> URL? {
		let file = directory(of: identifier).appending(path: Self.pictureName)
		return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? file : nil
	}

	/// The text of each page, or nil while the submission awaits its reading.
	func pageTexts(of identifier: UUID) -> [String]? {
		(try? Data(contentsOf: directory(of: identifier).appending(path: Self.pageTextsName)))
			.flatMap { try? JSONDecoder().decode([String].self, from: $0) }
	}

	/// Stores what was read from a submission's document: the picture, and the page texts unless
	/// they await recognition. Each is written to a temporary name and renamed, because the other
	/// process may read the submission meanwhile.
	static func write(_ contents: DocumentContents, into directory: URL) throws {
		var files: [(String, Data)] = contents.thumbnail.map { [(pictureName, $0)] } ?? []
		if !contents.awaitsRecognition {
			try files.append((pageTextsName, JSONEncoder().encode(contents.pageTexts)))
		}
		for (name, data) in files {
			let temporary = directory.appending(path: "\(name).\(UUID().uuidString)")
			let destination = directory.appending(path: name)
			try data.write(to: temporary)
			if rename(temporary.path(percentEncoded: false), destination.path(percentEncoded: false)) != 0 {
				let failure = String(cString: strerror(errno))
				try? FileManager.default.removeItem(at: temporary)
				throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: failure])
			}
		}
	}

	/// Stores what the application read from a submission the share extension left to it.
	func store(_ contents: DocumentContents, for identifier: UUID) throws {
		try Self.write(contents, into: directory(of: identifier))
	}

	/// Where the body of one upload is written and uploaded from.
	func bodyFile(of attempt: SubmissionAttempt) -> URL {
		directory(of: attempt.submission).appending(path: "\(Self.bodyName).\(attempt.identifier.uuidString)")
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
		case .rejected, .refusedToken, .tokenReplaced, .unavailable:
			rename(temporaryPath, directory.appending(path: Self.answerName).path(percentEncoded: false))
		}
		if renamed != 0 {
			let failure = errno
			try? FileManager.default.removeItem(at: temporary)
			guard failure == EEXIST else {
				throw .queueUnwritable(String(cString: strerror(failure)))
			}
		}
		guard let entry = entry(identifier) else {
			return answer
		}
		if case .archived = entry.answer {
			removeBytes(of: entry)
		}
		return entry.answer ?? answer
	}

	/// Records the archive's answer to one upload, or the lack of one, whichever process the upload's
	/// session delivered it to, and removes that upload's body, which no other upload reads. Answers
	/// nil when the submission is gone. A refusal of the token of an attempt prepared before the last
	/// accepted token is not final, because it says nothing of the token that replaced it. The
	/// acceptance is read after the refusal is written, and `tokenAccepted` writes the acceptance
	/// before it reads the refusals, so one of the two releases every such refusal.
	@discardableResult
	public func receive(
		_ answer: DocumentSubmissionAnswer?,
		for attempt: SubmissionAttempt
	) throws(QueueFailure) -> SubmissionAnswerRecord? {
		try? FileManager.default.removeItem(at: bodyFile(of: attempt))
		guard let entry = entry(attempt.submission) else {
			return nil
		}
		let recorded = try record(
			SubmissionAnswerRecord(answer: answer, previous: entry.answer),
			for: attempt.submission
		)
		guard case .refusedToken = recorded, let acceptedAt = tokenAcceptedAt, attempt.preparedAt < acceptedAt else {
			return recorded
		}
		return try record(.tokenReplaced(acceptedAt: acceptedAt), for: attempt.submission)
	}

	/// The archive accepted a token that permits sending at `now`. Every token refusal recorded so far
	/// answered an upload prepared before, so each submission is sent again with the new token.
	public func tokenAccepted(at now: Date = .now) {
		let acceptance = root.appending(path: Self.tokenAcceptanceName)
		let temporary = root.appending(path: "\(Self.tokenAcceptanceName).\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let written = (try? JSONEncoder().encode(now).write(to: temporary)) != nil
		if !written || rename(temporary.path(percentEncoded: false), acceptance.path(percentEncoded: false)) != 0 {
			try? FileManager.default.removeItem(at: temporary)
		}
		for entry in entries() {
			if case .refusedToken? = entry.answer {
				_ = try? record(.tokenReplaced(acceptedAt: now), for: entry.id)
			}
		}
	}

	private var tokenAcceptedAt: Date? {
		(try? Data(contentsOf: root.appending(path: Self.tokenAcceptanceName)))
			.flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
	}

	/// Removes the document and the body of every upload of an archived submission, because the
	/// archive holds the bytes. A body whose upload was cancelled, such as by a force quit, is never
	/// answered, so the answer to its upload cannot remove it.
	private func removeBytes(of entry: SubmissionEntry) {
		if let document = documentFile(of: entry) {
			try? FileManager.default.removeItem(at: document)
		}
		let files = (try? FileManager.default.contentsOfDirectory(
			at: directory(of: entry.id),
			includingPropertiesForKeys: nil
		)) ?? []
		for file in files where file.lastPathComponent.hasPrefix("\(Self.bodyName).") {
			try? FileManager.default.removeItem(at: file)
		}
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
