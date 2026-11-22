import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Owns the application's single window, switches child screens inside a persistent container
/// controller so the frame stays intact, manages toolbar & facets, and reports library attendance.
final class MainWindowController: NSWindowController, NSWindowDelegate {
	private enum Screen: Equatable {
		case starting
		case failedToStart(StartFailureWording)
		case fault(String)
		case connectionForm(initialAddress: String?, instruction: String?, cancellable: Bool)
		case libraryWorkspace
		case stopped(String)
	}

	private static let windowAutosaveName = "org.schublade.mainWindow"

	private let applicationCommands: any ApplicationCommands
	private let libraryQueries: any LibraryQueries
	private let collectorCommands: any CollectorCommands
	private let persistsWindowState: Bool
	private let wordingContextProvider: () -> WordingContext
	private let onAttendanceChanged: (Bool) -> Void

	private let containerController = WindowContainerViewController()
	private var toolbarController: WorkspaceToolbarController?
	private var workspaceController: LibraryWorkspaceViewController?

	private var latestSituation = ApplicationSituation.starting
	private var shownWorkspace: LibraryWorkspacePresentation?
	private var latestFacets: LibraryFacets?
	private var fetchedFacetsRevision: UInt64 = 0
	private var newestFacetsRequest: UInt64 = 0
	private var navigation = LibraryNavigationState()
	private var activeScreen: Screen?
	private(set) var isAttending = false

	var activeWorkspaceController: LibraryWorkspaceViewController? {
		workspaceController
	}

	init(
		applicationCommands: any ApplicationCommands,
		libraryQueries: any LibraryQueries,
		collectorCommands: any CollectorCommands,
		persistsWindowState: Bool,
		wordingContextProvider: @escaping () -> WordingContext = { WordingContext.current() },
		onAttendanceChanged: @escaping (Bool) -> Void
	) {
		self.applicationCommands = applicationCommands
		self.libraryQueries = libraryQueries
		self.collectorCommands = collectorCommands
		self.persistsWindowState = persistsWindowState
		self.wordingContextProvider = wordingContextProvider
		self.onAttendanceChanged = onAttendanceChanged

		let mainWindow = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 1340, height: 820),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		mainWindow.minSize = NSSize(width: 900, height: 560)
		mainWindow.title = "Schublade"
		mainWindow.toolbarStyle = .unified
		mainWindow.isReleasedWhenClosed = false
		mainWindow.identifier = InterfaceIdentifier.mainWindow
		mainWindow.contentViewController = containerController
		mainWindow.setFrame(NSRect(x: 0, y: 0, width: 1340, height: 820), display: false)
		mainWindow.center()
		if persistsWindowState {
			mainWindow.setFrameAutosaveName(Self.windowAutosaveName)
		}

		super.init(window: mainWindow)
		mainWindow.delegate = self
		navigation.inspectorVisible = mainWindow.frame.width >= 1280
		configureToolbar()
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
			if !Self.allowsReplacingToken(library.archive) {
				navigation.replacingTokenOrigin = nil
			}
			let copyRevision = library.contentRevision
			if copyRevision != fetchedFacetsRevision, Self.libraryReadable(library.archive) {
				refreshFacets(expectedRevision: copyRevision)
			}
		} else {
			navigation.replacingTokenOrigin = nil
			latestFacets = nil
			fetchedFacetsRevision = 0
		}

		let resolved = WindowContent.resolve(
			situation: situation,
			navigation: navigation,
			facets: latestFacets,
			context: wordingContextProvider()
		)
		let desired = screen(for: resolved)
		if desired != activeScreen {
			activeScreen = desired
			displayScreen(desired)
			recomputeAttendance()
		}
		updateWorkspacePresentation(from: resolved, situation: situation)
	}

	func contentRevisionChanged(to revision: UInt64) {
		if readableArchiveStatus() != nil {
			refreshFacets(expectedRevision: revision)
		}
		workspaceController?.contentRevisionChanged(to: revision)
	}

	func windowDidBecomeKey(_: Notification) {
		recomputeAttendance()
		if readableArchiveStatus() != nil {
			libraryQueries.synchronize()
		}
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

	private func screen(for content: WindowContent) -> Screen {
		switch content {
		case .starting:
			.starting
		case let .failedToStart(wording):
			.failedToStart(wording)
		case let .fault(message):
			.fault(message)
		case let .connectionForm(initialAddress, instruction, cancellable):
			.connectionForm(initialAddress: initialAddress, instruction: instruction, cancellable: cancellable)
		case .libraryWorkspace:
			.libraryWorkspace
		case let .stopped(message):
			.stopped(message)
		}
	}

	private func displayScreen(_ screen: Screen) {
		switch screen {
		case .starting:
			showStatus("Starting Schublade…", detail: nil, identifier: InterfaceIdentifier.statusMessage)
		case let .failedToStart(wording):
			showStatus(wording.explanation, detail: wording.remedy, identifier: InterfaceIdentifier.startFailureMessage)
		case let .fault(message):
			showStatus(message, detail: nil, identifier: InterfaceIdentifier.statusMessage)
		case let .connectionForm(initialAddress, instruction, cancellable):
			workspaceController = nil
			window?.toolbar = nil
			let cancelHandler: (() -> Void)? = cancellable ? { [weak self] in
				self?.cancelTokenReplacement()
			} : nil
			containerController.display(ConnectionFormViewController(
				commands: applicationCommands,
				initialAddress: initialAddress,
				instruction: instruction,
				onCancel: cancelHandler
			))
		case .libraryWorkspace:
			let workspace = buildWorkspaceController()
			workspaceController = workspace
			workspace.listController.onShownDocumentsChanged = { [weak self] shown in
				guard let self, let presentation = shownWorkspace else {
					return
				}
				window?.subtitle = presentation.windowSubtitle(shownDocuments: shown)
			}
			containerController.display(workspace)
			window?.toolbar = toolbarController?.toolbar
			workspace.wireKeyViewLoop()
			window?.makeFirstResponder(workspace.listController.focusTargetView)
		case let .stopped(message):
			showStatus(message, detail: nil, identifier: InterfaceIdentifier.statusMessage)
		}
	}

	private func recomputeAttendance() {
		let nextAttending: Bool = if activeScreen == .libraryWorkspace, let window {
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

	/// Shows the page that settles what a notification or the menu reported.
	func open(_ action: AttentionAction) {
		present()
		switch action {
		case .replaceToken:
			beginTokenReplacement()
		case let .decideBacklog(folder), let .openFolder(folder):
			updateNavigation { navigation in
				navigation.destination = .folder(folder)
				navigation.selectedDocument = nil
			}
		}
	}
}

private extension MainWindowController {
	func configureToolbar() {
		toolbarController = WorkspaceToolbarController(
			onNavigateBack: { [weak self] in self?.navigateBack() },
			onSelectOrder: { [weak self] order in self?.setBrowseOrder(order) },
			onSearchTextChanged: { [weak self] query in self?.setSearchText(query) },
			onShareDocument: { [weak self] anchor in
				self?.workspaceController?.shareSelectedDocument(anchoredTo: anchor)
			},
			onToggleInspector: { [weak self] in self?.toggleInspector() }
		)
	}

	func buildWorkspaceController() -> LibraryWorkspaceViewController {
		LibraryWorkspaceViewController(
			queries: libraryQueries,
			collectorCommands: collectorCommands,
			renderMode: .interactive,
			persistsState: persistsWindowState,
			wordingContextProvider: wordingContextProvider,
			onNavigationChange: { [weak self] mutate in
				self?.updateNavigation(mutate)
			},
			onReplaceToken: { [weak self] in
				self?.beginTokenReplacement()
			},
			onFocusSearch: { [weak self] in
				self?.toolbarController?.focusSearchField()
			}
		)
	}

	func showStatus(_ message: String, detail: String?, identifier: String) {
		workspaceController = nil
		window?.toolbar = nil
		containerController.display(StatusMessageViewController(
			message: message,
			detail: detail,
			identifier: identifier
		))
	}

	func updateWorkspacePresentation(from content: WindowContent, situation: ApplicationSituation) {
		guard case let .libraryWorkspace(workspace) = content,
		      let workspaceController,
		      case let .running(statuses) = situation
		else {
			window?.title = "Schublade"
			window?.subtitle = ""
			window?.toolbar = nil
			return
		}
		shownWorkspace = workspace
		window?.title = workspace.windowTitle
		window?.subtitle = workspace.windowSubtitle(shownDocuments: workspaceController.listController.shownDocuments)
		if window?.toolbar !== toolbarController?.toolbar {
			window?.toolbar = toolbarController?.toolbar
		}
		toolbarController?.apply(
			workspace: workspace,
			navigation: navigation,
			hasSelectedDocument: navigation.selectedDocument != nil
		)
		workspaceController.render(workspace: workspace, statuses: statuses, navigation: navigation)
	}

	func updateNavigation(_ mutate: (inout LibraryNavigationState) -> Void) {
		mutate(&navigation)
		render(latestSituation)
	}

	func setBrowseOrder(_ order: ListingOrder) {
		updateNavigation { $0.browseOrder = order }
	}

	func setSearchText(_ text: String) {
		guard navigation.searchText != text else {
			return
		}
		updateNavigation { $0.searchText = text }
	}

	func toggleInspector() {
		updateNavigation { $0.inspectorVisible.toggle() }
	}

	func navigateBack() {
		updateNavigation { navigation in
			navigation.destination = navigation.previousDestination ?? .library(.allDocuments, title: nil)
			navigation.previousDestination = nil
			navigation.selectedDocument = nil
		}
	}

	private func readableArchiveStatus() -> LibraryStatus? {
		guard case let .running(statuses) = latestSituation, let library = statuses.library else {
			return nil
		}
		return Self.libraryReadable(library.archive) ? library : nil
	}

	func beginTokenReplacement() {
		guard case let .running(statuses) = latestSituation,
		      case let .configured(origin, _, _, _, _)? = statuses.library?.archive,
		      Self.allowsReplacingToken(statuses.library?.archive)
		else {
			return
		}
		navigation.replacingTokenOrigin = origin
		render(latestSituation)
	}

	func cancelTokenReplacement() {
		navigation.replacingTokenOrigin = nil
		render(latestSituation)
	}

	func refreshFacets(expectedRevision: UInt64) {
		newestFacetsRequest &+= 1
		let requestNumber = newestFacetsRequest
		Task {
			guard let facets = try? await libraryQueries.facets(),
			      requestNumber == newestFacetsRequest
			else {
				return
			}
			fetchedFacetsRevision = max(expectedRevision, facets.contentRevision)
			latestFacets = facets
			render(latestSituation)
		}
	}

	static func libraryReadable(_ archive: ArchiveConnection) -> Bool {
		guard case let .configured(_, _, _, permission, _) = archive else {
			return false
		}
		return permission != .collectOnly
	}

	static func allowsReplacingToken(_ archive: ArchiveConnection?) -> Bool {
		guard case let .configured(_, _, condition, permission, _) = archive else {
			return false
		}
		if permission == .collectOnly {
			return true
		}
		if case .suspended = condition {
			return true
		}
		return false
	}
}
