import ApplicationBindings
import Foundation
import SubmissionQueue

/// Where this process keeps its state. Everything that differs between the installed application
/// and the end-to-end test is here, so no other type reads the process environment.
struct ApplicationEnvironment {
	let applicationConfiguration: ApplicationConfiguration
	/// Where submissions wait to be sent and answered, and where the share extension reads the
	/// connected archive.
	let sharedContainer: SharedContainer
	let transferSessions: TransferSessions
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

	/// The copy in Application Support and its caches in Caches, under the bundle identifier; the
	/// submissions and the token where the share extension reads them, in the App Group and the
	/// Keychain access group. The iPhone has no collector, and keeps at most 500 MB of originals.
	private static func installed() -> ApplicationEnvironment {
		let installation: SharedInstallation
		let container: SharedContainer
		do throws(SharedInstallation.ResolutionFailure) {
			installation = try SharedInstallation.read()
			container = try installation.container()
		} catch {
			preconditionFailure("The application is not signed with its App Group: \(error)")
		}
		let bundleIdentifier = installation.applicationBundleIdentifier
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
				credentialStorage: installation.credentialStorage,
				collection: .absent
			),
			sharedContainer: container,
			transferSessions: .background(installation)
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

	/// A new temporary directory and a Keychain item under a service name of its own, in the shared
	/// access group, so a test never reads the state of an installed application. The token is not
	/// kept in process memory, because sending reads it from the Keychain without the core, as the
	/// share extension does.
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
					accessGroup: try? SharedInstallation.read().keychainAccessGroup
				),
				collection: .absent
			),
			sharedContainer: SharedContainer(root: baseDirectory.appending(
				path: "shared",
				directoryHint: .isDirectory
			)),
			transferSessions: .ephemeral
		)
	}
	#endif
}
