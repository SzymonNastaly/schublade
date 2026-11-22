import AppKit
import ApplicationBindings

/// Owns the application's single window, switches child screens inside a persistent container
/// controller so the frame stays intact, and reports library attendance accurately.
final class MainWindowController: NSWindowController, NSWindowDelegate {
	private enum Screen: Equatable {
		case starting
		case failedToStart(ApplicationStartFailure)
		case fault(ApplicationFault)
		case connectionForm(initialAddress: String?, instruction: String?, cancellable: Bool)
		case archiveOutdated
		case documentList
		case stopped
	}

	private let applicationCommands: any ApplicationCommands
	private let libraryQueries: any LibraryQueries
	private let onAttendanceChanged: (Bool) -> Void
	private let containerController = WindowContainerViewController()

	private var latestSituation = ApplicationSituation.starting
	private var activeScreen: Screen?
	private var replacingTokenOrigin: String?
	private var documentListController: DocumentListViewController?
	private(set) var isAttending = false

	var activeDocumentListController: DocumentListViewController? {
		documentListController
	}

	init(
		applicationCommands: any ApplicationCommands,
		libraryQueries: any LibraryQueries,
		onAttendanceChanged: @escaping (Bool) -> Void
	) {
		self.applicationCommands = applicationCommands
		self.libraryQueries = libraryQueries
		self.onAttendanceChanged = onAttendanceChanged

		let mainWindow = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 1340, height: 820),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		mainWindow.minSize = NSSize(width: 900, height: 560)
		mainWindow.title = "Schublade"
		mainWindow.isReleasedWhenClosed = false
		mainWindow.identifier = InterfaceIdentifier.mainWindow
		mainWindow.contentViewController = containerController
		mainWindow.setContentSize(NSSize(width: 1340, height: 820))
		mainWindow.center()

		super.init(window: mainWindow)
		mainWindow.delegate = self
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func present() {
		if NSApp.activationPolicy() != .regular {
			NSApp.setActivationPolicy(.regular)
		}
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate()
		recomputeAttendance()
	}

	func render(_ situation: ApplicationSituation) {
		latestSituation = situation
		if case let .running(statuses) = situation, let library = statuses.library {
			if !Self.isSuspended(library.archive) {
				replacingTokenOrigin = nil
			}
		} else {
			replacingTokenOrigin = nil
		}

		let desired = desiredScreen(for: situation)
		if desired != activeScreen {
			activeScreen = desired
			displayScreen(desired)
			recomputeAttendance()
		}

		if case let .running(statuses) = situation, let documentListController, let library = statuses.library {
			documentListController.render(libraryStatus: library, libraryFault: statuses.libraryFault)
		}
	}

	func contentRevisionChanged(to revision: UInt64) {
		documentListController?.contentRevisionChanged(to: revision)
	}

	func windowDidBecomeKey(_: Notification) {
		recomputeAttendance()
	}

	func windowDidChangeOcclusionState(_: Notification) {
		recomputeAttendance()
	}

	func windowDidMiniaturize(_: Notification) {
		recomputeAttendance()
	}

	func windowDidDeminiaturize(_: Notification) {
		recomputeAttendance()
	}

	func windowWillClose(_: Notification) {
		if isAttending {
			isAttending = false
			onAttendanceChanged(false)
		}
		NSApp.setActivationPolicy(.accessory)
	}

	private func desiredScreen(for situation: ApplicationSituation) -> Screen {
		switch situation {
		case .starting:
			return .starting
		case let .failedToStart(failure):
			return .failedToStart(failure)
		case let .running(statuses):
			guard let library = statuses.library else {
				return statuses.libraryFault.map(Screen.fault) ?? .starting
			}
			return screenForLibraryArchive(library.archive)
		case .stopped:
			return .stopped
		}
	}

	private func screenForLibraryArchive(_ archive: ArchiveConnection) -> Screen {
		switch archive {
		case .notConfigured:
			return .connectionForm(initialAddress: nil, instruction: nil, cancellable: false)
		case let .configured(origin, _, condition, permission, _):
			if permission == .collectOnly {
				let guidance = "This token can only add documents and cannot read the archive. "
					+ "Paste a token with read permission from Settings."
				return .connectionForm(initialAddress: origin, instruction: guidance, cancellable: false)
			}
			if case .suspended = condition, let originToReplace = replacingTokenOrigin {
				let guidance = "Schublade refused the current token. Paste a new API token from Settings."
				return .connectionForm(initialAddress: originToReplace, instruction: guidance, cancellable: true)
			}
			if case .archiveOutdated = condition {
				return .archiveOutdated
			}
			return .documentList
		}
	}

	private func displayScreen(_ screen: Screen) {
		switch screen {
		case .starting:
			showStatus("Starting Schublade…", identifier: InterfaceIdentifier.statusMessage)
		case let .failedToStart(failure):
			let sentence = ApplicationFailureWording.startFailureSentence(failure)
			showStatus(sentence, identifier: InterfaceIdentifier.startFailureMessage)
		case let .fault(fault):
			showStatus(ApplicationFailureWording.faultSentence(fault), identifier: InterfaceIdentifier.statusMessage)
		case let .connectionForm(initialAddress, instruction, cancellable):
			documentListController = nil
			let cancelHandler: (() -> Void)? = cancellable ? { [weak self] in
				self?.cancelTokenReplacement()
			} : nil
			containerController.display(ConnectionFormViewController(
				commands: applicationCommands,
				initialAddress: initialAddress,
				instruction: instruction,
				onCancel: cancelHandler
			))
		case .archiveOutdated:
			showStatus("Update your archive to use the library.", identifier: InterfaceIdentifier.statusMessage)
		case .documentList:
			let listController = DocumentListViewController(queries: libraryQueries) { [weak self] in
				self?.beginTokenReplacement()
			}
			documentListController = listController
			containerController.display(listController)
		case .stopped:
			showStatus("Schublade stopped.", identifier: InterfaceIdentifier.statusMessage)
		}
	}

	private func showStatus(_ message: String, identifier: String) {
		documentListController = nil
		containerController.display(StatusMessageViewController(message: message, identifier: identifier))
	}

	private func beginTokenReplacement() {
		guard
			case let .running(statuses) = latestSituation,
			case let .configured(origin, _, condition, _, _)? = statuses.library?.archive,
			case .suspended = condition
		else {
			return
		}
		replacingTokenOrigin = origin
		render(latestSituation)
	}

	private func cancelTokenReplacement() {
		replacingTokenOrigin = nil
		render(latestSituation)
	}

	private func recomputeAttendance() {
		let nextAttending: Bool = if activeScreen == .documentList, let window {
			window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
		} else {
			false
		}
		guard nextAttending != isAttending else {
			return
		}
		isAttending = nextAttending
		onAttendanceChanged(nextAttending)
	}

	private static func isSuspended(_ archive: ArchiveConnection) -> Bool {
		switch archive {
		case .notConfigured:
			return false
		case let .configured(_, _, condition, _, _):
			if case .suspended = condition {
				return true
			}
			return false
		}
	}
}
