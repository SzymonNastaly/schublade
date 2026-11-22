import ApplicationBindings
import Foundation

/// Where this process keeps its state. Everything that differs between the installed application
/// and the end-to-end test is here, so no other type reads the process environment.
struct ApplicationEnvironment {
	let applicationConfiguration: ApplicationConfiguration
	let isIsolated: Bool

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

	/// The state in Application Support, caches in Caches, and the token in the Keychain, all under
	/// the bundle identifier.
	private static func installed() -> ApplicationEnvironment {
		guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
			preconditionFailure("The application bundle has no identifier")
		}
		let dataDirectory = URL.applicationSupportDirectory.appending(
			path: bundleIdentifier,
			directoryHint: .isDirectory
		)
		let cacheDirectory = URL.cachesDirectory.appending(
			path: bundleIdentifier,
			directoryHint: .isDirectory
		)
		return ApplicationEnvironment(
			applicationConfiguration: ApplicationConfiguration(
				dataDirectory: dataDirectory.path(percentEncoded: false),
				cacheDirectory: cacheDirectory.path(percentEncoded: false),
				originalStorageLimit: nil,
				credentialStorage: .keychain(serviceName: bundleIdentifier),
				collection: .collector
			),
			isIsolated: false
		)
	}

	#if DEBUG
	/// A new temporary directory and the token in process memory, so a test never reads the
	/// Keychain or the state of an installed application.
	private static func isolated() -> ApplicationEnvironment {
		let baseDirectory = URL.temporaryDirectory.appending(
			path: "schublade_application_\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		let dataDirectory = baseDirectory.appending(path: "data", directoryHint: .isDirectory)
		let cacheDirectory = baseDirectory.appending(path: "cache", directoryHint: .isDirectory)
		return ApplicationEnvironment(
			applicationConfiguration: ApplicationConfiguration(
				dataDirectory: dataDirectory.path(percentEncoded: false),
				cacheDirectory: cacheDirectory.path(percentEncoded: false),
				originalStorageLimit: nil,
				credentialStorage: .processMemory,
				collection: .collector
			),
			isIsolated: true
		)
	}
	#endif
}
