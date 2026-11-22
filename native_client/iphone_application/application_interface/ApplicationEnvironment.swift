import ApplicationBindings
import Foundation
import SubmissionQueue

/// Where this process keeps its state. Everything that differs between the installed application
/// and the end-to-end test is here, so no other type reads the process environment.
struct ApplicationEnvironment {
	let applicationConfiguration: ApplicationConfiguration
	/// Where submissions wait to be sent and answered.
	let submissionQueueRoot: URL
	/// The background session's identifier, or nil for a session that ends with the process, as a
	/// test needs.
	let transferSessionIdentifier: String?
	/// In a Debug build, an archive to connect at launch and files to send, so a screen examination
	/// on the simulator needs no typing.
	var examination: Examination?

	struct Examination {
		let address: String
		let token: String
		let documents: URL?
	}

	var transferConfiguration: URLSessionConfiguration {
		guard let transferSessionIdentifier else {
			return .ephemeral
		}
		return SubmissionTransfer.backgroundConfiguration(identifier: transferSessionIdentifier, sharedContainer: nil)
	}

	/// The installed environment, or in a Debug build started with
	/// `SCHUBLADE_APPLICATION_ENVIRONMENT=isolated`, the isolated one.
	static func current() -> ApplicationEnvironment {
		#if DEBUG
		let variables = ProcessInfo.processInfo.environment
		if variables["SCHUBLADE_APPLICATION_ENVIRONMENT"] == "isolated" {
			var environment = isolated()
			environment.examination = examination(variables)
			return environment
		}
		#endif
		return installed()
	}

	/// The state in Application Support, caches in Caches, and the token in the Keychain, under the
	/// bundle identifier. The iPhone has no collector, and keeps at most 500 MB of originals.
	private static func installed() -> ApplicationEnvironment {
		guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
			preconditionFailure("The application bundle has no identifier")
		}
		return ApplicationEnvironment(
			applicationConfiguration: ApplicationConfiguration(
				dataDirectory: URL.applicationSupportDirectory.appending(
					path: bundleIdentifier,
					directoryHint: .isDirectory
				).path(percentEncoded: false),
				cacheDirectory: URL.cachesDirectory.appending(
					path: bundleIdentifier,
					directoryHint: .isDirectory
				).path(percentEncoded: false),
				originalStorageLimit: 500_000_000,
				credentialStorage: .sharedKeychain(serviceName: bundleIdentifier, accessGroup: nil),
				collection: .absent
			),
			submissionQueueRoot: URL.applicationSupportDirectory.appending(
				path: "\(bundleIdentifier)/submission_queue",
				directoryHint: .isDirectory
			),
			transferSessionIdentifier: "\(bundleIdentifier).submission-transfer"
		)
	}

	#if DEBUG
	/// The examination that the launch variables describe, if they name an archive and a token.
	private static func examination(_ variables: [String: String]) -> Examination? {
		guard let address = variables["SCHUBLADE_EXAMINATION_ARCHIVE"],
		      let token = variables["SCHUBLADE_EXAMINATION_TOKEN"]
		else {
			return nil
		}
		return Examination(
			address: address,
			token: token,
			documents: variables["SCHUBLADE_EXAMINATION_DOCUMENTS"].map { URL(filePath: $0) }
		)
	}

	/// A new temporary directory and a Keychain item under a service name of its own, so a test
	/// never reads the state of an installed application. The token is not kept in process memory,
	/// because sending reads it from the Keychain without the core, as the share extension does.
	static func isolated() -> ApplicationEnvironment {
		let baseDirectory = URL.temporaryDirectory.appending(
			path: "schublade_application_\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		return ApplicationEnvironment(
			applicationConfiguration: ApplicationConfiguration(
				dataDirectory: baseDirectory.appending(path: "data", directoryHint: .isDirectory)
					.path(percentEncoded: false),
				cacheDirectory: baseDirectory.appending(path: "cache", directoryHint: .isDirectory)
					.path(percentEncoded: false),
				originalStorageLimit: nil,
				credentialStorage: .sharedKeychain(
					serviceName: "org.schublade.iphone.isolated.\(UUID().uuidString)",
					accessGroup: nil
				),
				collection: .absent
			),
			submissionQueueRoot: baseDirectory.appending(path: "submission_queue", directoryHint: .isDirectory),
			transferSessionIdentifier: nil
		)
	}
	#endif
}
