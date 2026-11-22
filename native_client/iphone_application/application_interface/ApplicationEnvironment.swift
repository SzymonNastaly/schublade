import ApplicationBindings
import Foundation

/// Where this process keeps its state. Everything that differs between the installed application
/// and the end-to-end test is here, so no other type reads the process environment.
struct ApplicationEnvironment {
	let applicationConfiguration: ApplicationConfiguration

	/// The installed environment, or in a Debug build started with
	/// `SCHUBLADE_APPLICATION_ENVIRONMENT=isolated`, the isolated one.
	static func current() -> ApplicationEnvironment {
		#if DEBUG
		if ProcessInfo.processInfo.environment["SCHUBLADE_APPLICATION_ENVIRONMENT"] == "isolated" {
			return isolated()
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
			)
		)
	}

	#if DEBUG
	/// A new temporary directory and the token in process memory, so a test never reads the
	/// Keychain or the state of an installed application.
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
				credentialStorage: .processMemory,
				collection: .absent
			)
		)
	}
	#endif
}
