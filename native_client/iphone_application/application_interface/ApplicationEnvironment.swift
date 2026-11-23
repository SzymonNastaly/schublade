import ApplicationBindings
import Foundation
import SubmissionQueue

/// Where this process keeps its state. Everything that differs between the installed application
/// and the end-to-end test is here, so no other type reads the process environment.
struct ApplicationEnvironment {
	var applicationConfiguration: ApplicationConfiguration
	/// Where submissions wait to be sent and answered, and where the share extension reads the
	/// connected archive.
	var sharedContainer: SharedContainer
	let transferSessions: TransferSessions
	/// A person's choices, which the isolated environment forgets at every launch.
	let preferences: ApplicationPreferences
	/// In a Debug build, an archive to connect at launch and files to send, so a screen examination
	/// on the simulator needs no typing.
	var examination: Examination?

	/// How this process uploads.
	enum TransferSessions {
		/// In background sessions, which continue while the application is suspended or ended.
		case background(SharedInstallation)
		/// In a session that ends with the process, as a test needs, because a background session
		/// cannot deliver its events to a test.
		case ephemeral

		var sendingConfiguration: URLSessionConfiguration {
			switch self {
			case let .background(installation):
				SubmissionTransfer.backgroundConfiguration(
					identifier: installation.applicationTransferSessionIdentifier,
					sharedContainer: installation.applicationGroupIdentifier
				)
			case .ephemeral:
				.ephemeral
			}
		}

		/// The share extension's session when `identifier` names it, else nil.
		func shareExtensionConfiguration(identifier: String) -> URLSessionConfiguration? {
			guard case let .background(installation) = self,
			      identifier == installation.shareExtensionTransferSessionIdentifier
			else {
				return nil
			}
			return SubmissionTransfer.backgroundConfiguration(
				identifier: identifier,
				sharedContainer: installation.applicationGroupIdentifier
			)
		}
	}

	struct Examination {
		let address: String
		let token: String
		let documents: URL?
	}

	/// The names the share extension shares, and the App Group's container.
	private static func sharedInstallation() -> (SharedInstallation, SharedContainer) {
		do throws(SharedInstallation.ResolutionFailure) {
			let installation = try SharedInstallation.read()
			return try (installation, installation.container())
		} catch {
			preconditionFailure("The application is not signed with its App Group: \(error)")
		}
	}

	/// The installed environment, or in a Debug build started with
	/// `SCHUBLADE_APPLICATION_ENVIRONMENT=isolated`, the isolated one.
	static func current() -> ApplicationEnvironment {
		#if DEBUG
		let variables = ProcessInfo.processInfo.environment
		if variables["SCHUBLADE_APPLICATION_ENVIRONMENT"] == "isolated" {
			return examination(variables).map(examined) ?? isolated()
		}
		#endif
		return installed()
	}

	/// The copy in Application Support and its caches in Caches, under the bundle identifier; the
	/// submissions and the token where the share extension reads them, in the App Group and the
	/// Keychain access group. The iPhone has no collector, and keeps originals up to the limit a
	/// person chose in Settings, 500 MB until then.
	private static func installed() -> ApplicationEnvironment {
		let (installation, container) = sharedInstallation()
		let bundleIdentifier = installation.applicationBundleIdentifier
		let preferences = ApplicationPreferences(defaults: .standard)
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
				originalStorageLimit: preferences.originalStorageLimit,
				credentialStorage: installation.credentialStorage,
				collection: .absent
			),
			sharedContainer: container,
			transferSessions: .background(installation),
			preferences: preferences
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

	/// The isolated environment, except that the submissions, the record of the connected archive,
	/// and the token are where the share extension reads them, the installation's App Group and
	/// Keychain item, so the share sheet of an examined simulator sends to the examined archive.
	private static func examined(_ examination: Examination) -> ApplicationEnvironment {
		let (installation, container) = sharedInstallation()
		var environment = isolated()
		environment.sharedContainer = container
		environment.applicationConfiguration.credentialStorage = installation.credentialStorage
		environment.examination = examination
		return environment
	}

	/// A new temporary directory, preferences emptied at every launch, and a Keychain item under a
	/// service name of its own, in the shared access group, so a test never reads the state of an
	/// installed application. The token is not
	/// kept in process memory, because sending reads it from the Keychain without the core, as the
	/// share extension does.
	static func isolated() -> ApplicationEnvironment {
		let baseDirectory = URL.temporaryDirectory.appending(
			path: "schublade_application_\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		let suite = "org.schublade.iphone.isolated"
		let defaults = UserDefaults(suiteName: suite) ?? .standard
		defaults.removePersistentDomain(forName: suite)
		let preferences = ApplicationPreferences(defaults: defaults)
		return ApplicationEnvironment(
			applicationConfiguration: ApplicationConfiguration(
				dataDirectory: baseDirectory.appending(path: "data", directoryHint: .isDirectory)
					.path(percentEncoded: false),
				cacheDirectory: baseDirectory.appending(path: "cache", directoryHint: .isDirectory)
					.path(percentEncoded: false),
				originalStorageLimit: preferences.originalStorageLimit,
				credentialStorage: .sharedKeychain(
					serviceName: "org.schublade.iphone.isolated.\(UUID().uuidString)",
					accessGroup: try? SharedInstallation.read().keychainAccessGroup
				),
				collection: .absent
			),
			sharedContainer: SharedContainer(root: baseDirectory.appending(
				path: "shared",
				directoryHint: .isDirectory
			)),
			transferSessions: .ephemeral,
			preferences: preferences
		)
	}
	#endif
}
