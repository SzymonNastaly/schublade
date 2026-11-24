import ApplicationBindings
import ApplicationPresentation

/// The one owner of the application's situations. It starts the core, follows both the library and
/// collector statuses with backoff on transient faults, and renders the window and menu bar item.
final class ApplicationController {
	private(set) var situation = ApplicationSituation.starting
	let statusItem: StatusItemController
	let mainWindowController: MainWindowController
	let environment: ApplicationEnvironment
	private let gateway: ApplicationGateway
	private let notifier: CollectorNotifier
	let preferences: ApplicationPreferences
	let loginItem: LoginItem
	private var launchOrigin = LaunchOrigin.person
	private var settingsWindowController: SettingsWindowController?
	private var windowDecided = false
	private var shownContentRevision: UInt64 = 0
	private var isTerminating = false
	private var startTask: Task<Bool, Never>?
	private var followTask: Task<Void, Never>?

	var applicationCommands: any ApplicationCommands {
		gateway
	}

	var libraryQueries: any LibraryQueries {
		gateway
	}

	var collectorCommands: any CollectorCommands {
		gateway
	}

	init(environment: ApplicationEnvironment) {
		let gateway = ApplicationGateway()
		let statusItem = StatusItemController(queries: gateway)
		let preferences = ApplicationPreferences(isolated: environment.isIsolated)
		let mainWindowController = MainWindowController(
			applicationCommands: gateway,
			libraryQueries: gateway,
			collectorCommands: gateway,
			persistsWindowState: !environment.isIsolated,
			preferences: preferences
		) { attended in
			gateway.interfaceAttended(attended)
		}

		self.environment = environment
		self.gateway = gateway
		self.statusItem = statusItem
		self.mainWindowController = mainWindowController
		notifier = CollectorNotifier(isEnabled: !environment.isIsolated)
		self.preferences = preferences
		loginItem = LoginItem(isInert: environment.isIsolated)
		notifier.onOpen = { [weak mainWindowController] action in
			mainWindowController?.open(action)
		}

		statusItem.onOpenWindow = { [weak mainWindowController] in
			mainWindowController?.present()
		}
		statusItem.onOpenAction = { [weak mainWindowController] action in
			mainWindowController?.open(action)
		}
		statusItem.onOpenDocument = { [weak mainWindowController] document in
			mainWindowController?.show(.library(.allDocuments, title: nil), selecting: document)
		}
		statusItem.onOpenSettings = { [weak self] in
			self?.showSettings()
		}
		statusItem.onAddFolder = { [weak mainWindowController] in
			mainWindowController?.present()
			mainWindowController?.workspaceController?.enrollFolderAction(nil)
		}

		statusItem.render(situation)
		mainWindowController.render(situation)
	}

	/// Starts the core. A person's launch opens the window at once; a launch at login opens it only
	/// when the first statuses show that something needs a person.
	func launch(origin: LaunchOrigin) {
		launchOrigin = origin
		decideWindowIfPending()
		followTask = Task {
			await followApplication()
		}
	}

	func showMainWindow() {
		mainWindowController.present()
	}

	func showSettings() {
		let settings = settingsWindowController ?? SettingsWindowController(
			loginItem: loginItem,
			statusItem: statusItem.item,
			storage: StorageSettingsViewController(commands: gateway, preferences: preferences)
		) { [weak mainWindowController] in
			mainWindowController?.present()
			mainWindowController?.beginTokenReplacement()
		}
		settingsWindowController = settings
		renderSettings()
		settings.present()
	}

	private func renderSettings() {
		guard let settingsWindowController else {
			return
		}
		let statuses: ApplicationStatuses? = if case let .running(statuses) = situation {
			statuses
		} else {
			nil
		}
		settingsWindowController.render(statuses, context: ApplicationWordingContext.current())
	}

	/// The application came to the front, so the library asks the archive at once.
	func applicationActivated() {
		gateway.synchronize()
	}

	func systemResumed() {
		gateway.systemResumed()
	}

	func terminate() async {
		isTerminating = true
		_ = await startTask?.value
		followTask?.cancel()
		await gateway.shutdown()
		_ = await followTask?.value
	}

	private func followApplication() async {
		let startup = Task { await startGateway() }
		startTask = startup
		let started = await startup.value
		guard started, !isTerminating else {
			return
		}
		gateway.interfaceAttended(mainWindowController.isAttending)
		async let libraryFollowing: Void = followLibrary()
		async let collectorFollowing: Void = followCollector()
		_ = await (libraryFollowing, collectorFollowing)
		change(to: .stopped)
	}

	private func startGateway() async -> Bool {
		do {
			var configuration = environment.applicationConfiguration
			configuration.originalStorageLimit = preferences.originalStorageLimit
			try await gateway.start(configuration: configuration)
			return true
		} catch {
			change(to: .failedToStart(error))
			return false
		}
	}

	private func followLibrary() async {
		await followStatusLoop(
			readAfter: { [gateway] revision throws(ApplicationFault) in
				try await gateway.libraryStatusAfter(revision)
			},
			revisionOf: { $0.revision },
			onStatus: { [weak self] status in
				self?.applyLibraryStatus(status)
			},
			onFault: { [weak self] fault in
				self?.updateRunning { $0.libraryFault = fault }
			}
		)
	}

	private func followCollector() async {
		await followStatusLoop(
			readAfter: { [gateway] revision throws(ApplicationFault) in
				try await gateway.collectorStatusAfter(revision)
			},
			revisionOf: { $0.revision },
			onStatus: { [weak self] status in
				self?.notifier.observe(
					status,
					context: ApplicationWordingContext.current(),
					windowAttended: self?.mainWindowController.isAttending ?? false
				)
				self?.updateRunning {
					$0.collectorFault = nil
					$0.collector = status
				}
			},
			onFault: { [weak self] fault in
				self?.updateRunning { $0.collectorFault = fault }
			}
		)
	}

	private func applyLibraryStatus(_ status: LibraryStatus) {
		updateRunning {
			$0.libraryFault = nil
			$0.library = status
		}
		if status.contentRevision != shownContentRevision {
			shownContentRevision = status.contentRevision
			mainWindowController.contentRevisionChanged(to: shownContentRevision)
			statusItem.contentRevisionChanged()
		}
	}

	private func followStatusLoop<Status>(
		readAfter: (UInt64?) async throws(ApplicationFault) -> Status,
		revisionOf: (Status) -> UInt64,
		onStatus: (Status) -> Void,
		onFault: (ApplicationFault?) -> Void
	) async {
		var revision: UInt64?
		var retrySeconds = 1
		while !isTerminating, !Task.isCancelled {
			do {
				let status = try await readAfter(revision)
				revision = revisionOf(status)
				retrySeconds = 1
				onStatus(status)
			} catch {
				switch error {
				case .Stopped:
					return
				case .StoreFailed, .Unexpected:
					onFault(error)
					revision = nil
					try? await Task.sleep(for: .seconds(retrySeconds))
					retrySeconds = min(retrySeconds * 2, 30)
				}
			}
		}
	}

	private func updateRunning(_ mutate: (inout ApplicationStatuses) -> Void) {
		var statuses: ApplicationStatuses = if case let .running(current) = situation {
			current
		} else {
			ApplicationStatuses()
		}
		mutate(&statuses)
		change(to: .running(statuses))
	}

	private func change(to nextSituation: ApplicationSituation) {
		guard nextSituation != situation else {
			return
		}
		situation = nextSituation
		statusItem.render(nextSituation)
		mainWindowController.render(nextSituation)
		renderSettings()
		decideWindowIfPending()
		if LifecyclePresentation.registersLoginItem(
			situation: nextSituation,
			alreadyEstablished: preferences.loginItemEstablished
		) {
			// A registration the system refused is tried again at the next status.
			preferences.loginItemEstablished = loginItem.setEnabled(true)
		}
	}

	private func decideWindowIfPending() {
		guard !windowDecided else {
			return
		}
		switch LifecyclePresentation.launchWindow(origin: launchOrigin, situation: situation) {
		case .opens:
			windowDecided = true
			mainWindowController.present()
		case .staysClosed:
			windowDecided = true
		case .undecided:
			break
		}
	}
}
