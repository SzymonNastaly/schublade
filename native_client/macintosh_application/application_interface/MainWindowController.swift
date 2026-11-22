import AppKit
import ApplicationBindings

private enum LibraryUnavailableReason: Equatable {
	case collectOnlyToken
	case archiveOutdated
}

private enum MainWindowScreen: Equatable {
	case starting
	case failedToStart(ApplicationStartFailure)
	case connectionForm
	case libraryUnavailable(LibraryUnavailableReason)
	case documentList
	case stopped
}

/// Owns the application's single window, switches its screen when the situation changes, and
/// tracks whether the window attends the library and keeps the Regular activation policy.
final class MainWindowController: NSWindowController, NSWindowDelegate {
	private let applicationCommands: any ApplicationCommands
	private let libraryQueries: any LibraryQueries
	private let onAttendanceChanged: (Bool) -> Void

	private var activeScreen: MainWindowScreen?
	private var documentListController: DocumentListViewController?
	private(set) var isAttending = false

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
		setAttending(true)
	}

	func render(_ situation: ApplicationSituation) {
		let desiredScreen = Self.desiredScreen(for: situation)
		if desiredScreen != activeScreen {
			activeScreen = desiredScreen
			switch desiredScreen {
			case .starting:
				documentListController = nil
				window?.contentViewController = StatusMessageViewController(
					message: "Starting Schublade…",
					identifier: InterfaceIdentifier.statusMessage
				)
			case let .failedToStart(failure):
				documentListController = nil
				window?.contentViewController = StatusMessageViewController(
					message: Self.startFailureMessage(failure),
					identifier: InterfaceIdentifier.startFailureMessage
				)
			case .connectionForm:
				documentListController = nil
				window?.contentViewController = ConnectionFormViewController(commands: applicationCommands)
			case let .libraryUnavailable(reason):
				documentListController = nil
				window?.contentViewController = StatusMessageViewController(
					message: Self.unavailableMessage(reason),
					identifier: InterfaceIdentifier.statusMessage
				)
			case .documentList:
				let listController = DocumentListViewController(queries: libraryQueries)
				documentListController = listController
				window?.contentViewController = listController
			case .stopped:
				documentListController = nil
				window?.contentViewController = StatusMessageViewController(
					message: "Schublade stopped.",
					identifier: InterfaceIdentifier.statusMessage
				)
			}
		}

		if case let .running(statuses) = situation, let documentListController, let library = statuses.library {
			documentListController.render(libraryStatus: library)
		}
	}

	func contentRevisionChanged(to revision: UInt64) {
		documentListController?.contentRevisionChanged(to: revision)
	}

	func windowDidBecomeKey(_: Notification) {
		setAttending(true)
	}

	func windowDidResignKey(_: Notification) {
		setAttending(false)
	}

	func windowWillClose(_: Notification) {
		setAttending(false)
		NSApp.setActivationPolicy(.accessory)
	}

	private func setAttending(_ attending: Bool) {
		isAttending = attending
		onAttendanceChanged(attending)
	}

	private static func desiredScreen(for situation: ApplicationSituation) -> MainWindowScreen {
		switch situation {
		case .starting:
			return .starting
		case let .failedToStart(failure):
			return .failedToStart(failure)
		case let .running(statuses):
			guard let library = statuses.library else {
				return .starting
			}
			switch library.archive {
			case .notConfigured:
				return .connectionForm
			case let .configured(_, _, condition, permission, _):
				if permission == .collectOnly {
					return .libraryUnavailable(.collectOnlyToken)
				}
				if case .archiveOutdated = condition {
					return .libraryUnavailable(.archiveOutdated)
				}
				return .documentList
			}
		case .stopped:
			return .stopped
		}
	}

	private static func unavailableMessage(_ reason: LibraryUnavailableReason) -> String {
		switch reason {
		case .collectOnlyToken:
			"This token can only add documents and cannot read the archive."
		case .archiveOutdated:
			"Update your archive to use the library."
		}
	}

	private static func startFailureMessage(_ failure: ApplicationStartFailure) -> String {
		switch failure {
		case let .DataDirectoryUnavailable(detail):
			"Schublade could not create its folder in Application Support: \(detail)"
		case let .CacheDirectoryUnavailable(detail):
			"Schublade could not create its cache folder: \(detail)"
		case .DatabaseInUse:
			"Another copy of Schublade is already running on this Mac with the same data."
		case .DatabaseNewerThanApplication:
			"A newer version of Schublade ran on this Mac before, and this older version cannot read what it saved."
		case let .DatabaseUnusable(detail):
			"Schublade could not open its database: \(detail)"
		case let .WatcherUnavailable(detail):
			"Schublade could not start watching your folders: \(detail)"
		case let .Unexpected(detail):
			"Schublade could not start: \(detail)"
		}
	}
}

private final class StatusMessageViewController: NSViewController {
	private let message: String
	private let labelIdentifier: String

	init(message: String, identifier: String) {
		self.message = message
		labelIdentifier = identifier
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		let label = NSTextField(wrappingLabelWithString: message)
		label.alignment = .center
		label.textColor = .secondaryLabelColor
		label.translatesAutoresizingMaskIntoConstraints = false
		label.setAccessibilityIdentifier(labelIdentifier)
		view.addSubview(label)

		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
			label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
			label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
			label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
		])
	}
}
