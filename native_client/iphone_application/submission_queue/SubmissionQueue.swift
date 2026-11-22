import Foundation

/// The submissions on this device, one directory each, under a root that the application and its
/// share extension share. A submission is built under `incoming/` and renamed into `submissions/`
/// when complete, so no reader sees half of one, and its answer is written to a temporary name and
/// renamed too. No database is shared between the two processes.
public struct SubmissionQueue: Sendable {
	public enum QueueFailure: Error, Equatable {
		case documentUnreadable(String)
		case queueUnwritable(String)
	}

	private static let manifestName = "submission.json"
	private static let answerName = "answer.json"
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

	/// Moves `document` into a new submission, which then owns the file.
	public func enqueue(
		document: URL,
		fileName: String,
		kind: SubmissionFileKind,
		origin: SubmissionOrigin,
		pageCount: Int? = nil,
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
				createdAt: now
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
		return directories.compactMap { directory in
			guard let data = try? Data(contentsOf: directory.appending(path: Self.manifestName)),
			      let manifest = try? JSONDecoder().decode(SubmissionManifest.self, from: data)
			else {
				return nil
			}
			let answer = (try? Data(contentsOf: directory.appending(path: Self.answerName)))
				.flatMap { try? JSONDecoder().decode(SubmissionAnswerRecord.self, from: $0) }
			return SubmissionEntry(manifest: manifest, answer: answer)
		}
		.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
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

	/// Records the archive's answer. An archived submission gives up its bytes at once, because the
	/// archive holds them; a refused one keeps them, so a person can still share the file.
	public func record(_ answer: SubmissionAnswerRecord, for identifier: UUID) throws(QueueFailure) {
		let directory = directory(of: identifier)
		do {
			let temporary = directory.appending(path: "\(Self.answerName).\(UUID().uuidString)")
			try JSONEncoder().encode(answer).write(to: temporary)
			let answerFile = directory.appending(path: Self.answerName)
			if FileManager.default.fileExists(atPath: answerFile.path(percentEncoded: false)) {
				_ = try FileManager.default.replaceItemAt(answerFile, withItemAt: temporary)
			} else {
				try FileManager.default.moveItem(at: temporary, to: answerFile)
			}
		} catch {
			throw .queueUnwritable(error.localizedDescription)
		}
		try? FileManager.default.removeItem(at: bodyFile(of: identifier))
		guard case .archived = answer, let entry = entries().first(where: { $0.id == identifier }),
		      let document = documentFile(of: entry)
		else {
			return
		}
		try? FileManager.default.removeItem(at: document)
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
