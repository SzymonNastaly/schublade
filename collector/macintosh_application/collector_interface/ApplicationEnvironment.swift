import CollectionBindings
import Foundation

/// Where this process keeps its state. Everything that differs between the installed application
/// and the end-to-end test is here, so no other type reads the process environment.
struct ApplicationEnvironment {
	let collectorConfiguration: CollectorConfiguration

	/// The installed environment, or in a Debug build started with
	/// `SCHUBLADE_COLLECTOR_ENVIRONMENT=isolated`, the isolated one.
	static func current() -> ApplicationEnvironment {
		#if DEBUG
		if ProcessInfo.processInfo.environment["SCHUBLADE_COLLECTOR_ENVIRONMENT"] == "isolated" {
			return isolated()
		}
		#endif
		return installed()
	}

	/// The state in Application Support and the token in the Keychain, both under the bundle
	/// identifier.
	private static func installed() -> ApplicationEnvironment {
		guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
			preconditionFailure("The application bundle has no identifier")
		}
		let dataDirectory = URL.applicationSupportDirectory.appending(
			path: bundleIdentifier,
			directoryHint: .isDirectory
		)
		return ApplicationEnvironment(collectorConfiguration: CollectorConfiguration(
			dataDirectory: dataDirectory.path(percentEncoded: false),
			credentialStorage: .keychain(serviceName: bundleIdentifier)
		))
	}

	#if DEBUG
	/// A new temporary data directory and the token in process memory, so a test never reads the
	/// Keychain or the state of an installed application.
	private static func isolated() -> ApplicationEnvironment {
		let dataDirectory = URL.temporaryDirectory.appending(
			path: "schublade_collector_\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		return ApplicationEnvironment(collectorConfiguration: CollectorConfiguration(
			dataDirectory: dataDirectory.path(percentEncoded: false),
			credentialStorage: .processMemory
		))
	}
	#endif
}
