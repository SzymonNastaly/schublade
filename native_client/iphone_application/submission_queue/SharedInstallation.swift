import ApplicationBindings
import Foundation

/// What the application and its share extension share, as the Info.plist of each names it: the
/// App Group, the Keychain access group, and the two background sessions. The extension's own
/// bundle identifier differs from the application's, so every name derives from the application's
/// bundle identifier, which both Info.plists state.
public struct SharedInstallation: Sendable {
	public enum ResolutionFailure: Error, Equatable {
		case informationKeyMissing(String)
		case applicationGroupUnavailable(String)
	}

	public let applicationBundleIdentifier: String
	public let applicationGroupIdentifier: String
	public let keychainAccessGroup: String

	public static func read(from bundle: Bundle = .main) throws(ResolutionFailure) -> SharedInstallation {
		func value(_ key: String) throws(ResolutionFailure) -> String {
			guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
				throw .informationKeyMissing(key)
			}
			return value
		}
		return try SharedInstallation(
			applicationBundleIdentifier: value("SchubladeApplicationBundleIdentifier"),
			applicationGroupIdentifier: value("SchubladeApplicationGroup"),
			keychainAccessGroup: value("SchubladeKeychainAccessGroup")
		)
	}

	/// The App Group's container, which only a process signed with the group receives.
	public func container() throws(ResolutionFailure) -> SharedContainer {
		guard let root = FileManager.default
			.containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier)
		else {
			throw .applicationGroupUnavailable(applicationGroupIdentifier)
		}
		return SharedContainer(root: root)
	}

	/// The token's Keychain item, under the application's bundle identifier in the shared group.
	public var credentialStorage: CredentialStorage {
		.sharedKeychain(serviceName: applicationBundleIdentifier, accessGroup: keychainAccessGroup)
	}

	/// The application's own background session. Two processes must not attach to one background
	/// session at once, so each owns one.
	public var applicationTransferSessionIdentifier: String {
		"\(applicationBundleIdentifier).submission-transfer"
	}

	/// The share extension's background session. The application creates it only while the system
	/// delivers to it the answers that arrived after the extension ended.
	public var shareExtensionTransferSessionIdentifier: String {
		"\(applicationBundleIdentifier).share-extension.submission-transfer"
	}
}

/// The directory the application and its share extension share: the submission queue and the
/// record of the connected archive.
public struct SharedContainer: Sendable {
	public let root: URL

	public init(root: URL) {
		self.root = root
	}

	public var submissionQueue: SubmissionQueue {
		SubmissionQueue(root: root.appending(path: "submission_queue", directoryHint: .isDirectory))
	}

	private var connectedArchiveFile: URL {
		root.appending(path: "connected_archive.json")
	}

	public func connectedArchive() -> ConnectedArchive? {
		(try? Data(contentsOf: connectedArchiveFile))
			.flatMap { try? JSONDecoder().decode(ConnectedArchive.self, from: $0) }
	}

	/// Writes the record to a temporary file and renames it, so the share extension never reads half
	/// of one, or removes it for nil. The application is its only writer.
	public func record(_ archive: ConnectedArchive?) throws {
		guard let archive else {
			if FileManager.default.fileExists(atPath: connectedArchiveFile.path(percentEncoded: false)) {
				try FileManager.default.removeItem(at: connectedArchiveFile)
			}
			return
		}
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try JSONEncoder().encode(archive).write(to: connectedArchiveFile, options: .atomic)
	}
}

/// The archive the application is connected to, as the share extension needs it while offline:
/// where to send, and whether the token may send at all.
public struct ConnectedArchive: Codable, Equatable, Sendable {
	/// `https://archive.example.org`.
	public let origin: String
	/// Whether the token reads only part of the archive. The ingest route refuses such a token,
	/// because its answer names the document that holds the bytes already, which may lie outside
	/// that part.
	public let restricted: Bool

	/// Why a restricted token cannot send, for the application and the share extension alike.
	public static let restrictionSentence = "This token reads only part of your archive, so it cannot send "
		+ "documents. The archive's answer to an upload could name a document outside that part. To scan "
		+ "and share, connect a token without a restriction."

	public init(origin: String, restricted: Bool) {
		self.origin = origin
		self.restricted = restricted
	}

	/// `archive.example.org`, with the port when the origin names one, for sentences.
	public var host: String {
		guard let url = URL(string: origin), let host = url.host(percentEncoded: false) else {
			return origin
		}
		return url.port.map { "\(host):\($0)" } ?? host
	}
}
