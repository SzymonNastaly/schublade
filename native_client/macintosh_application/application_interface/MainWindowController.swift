import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Owns the application's single window, switches child screens inside a persistent container
/// controller so the frame stays intact, manages toolbar & facets, and reports library attendance.
final class MainWindowController: NSWindowController, NSWindowDelegate {
	private enum Screen: Equatable {
		case status(EmptyStatePresentation)
		/// A form stays while only the reason it states changes, as it does while a new token connects.
		case connectionForm(address: String?, cancellable: Bool)
		case libraryWorkspace
	}

	private static let windowAutosaveName = "org.schublade.mainWindow"

	private let applicationCommands: any ApplicationCommands
	private let libraryQueries: any LibraryQueries
	private let collectorCommands: any CollectorCommands
	private let persistsWindowState: Bool
	let preferences: ApplicationPreferences
	/// The place restored at launch, until the first facets show whether the copy still holds it.
	var restoredPlace: RememberedLibraryPlace?
	private let wordingContextProvider: () -> ApplicationWordingContext
	private let onAttendanceChanged: (Bool) -> Void

	private let containerController = WindowContainerViewController()
	private var toolbarController: WorkspaceToolbarController?
	private(set) var workspaceController: LibraryWorkspaceViewController?

	private(set) var latestSituation = ApplicationSituation.starting
	private var shownWorkspace: LibraryWorkspacePresentation?
	private var latestFacets: LibraryFacets?
	private var fetchedFacetsRevision: UInt64 = 0
	private var newestFacetsRequest: UInt64 = 0
	var navigation = LibraryNavigationState()
	private var activeScreen: Screen?
	private(set) var isAttending = false

	init(
		applicationCommands: any ApplicationCommands,
		libraryQueries: any LibraryQueries,
		collectorCommands: any CollectorCommands,
		persistsWindowState: Bool,
		preferences: ApplicationPreferences,
		wordingContextProvider: @escaping () -> ApplicationWordingContext = { ApplicationWordingContext.current() },
		onAttendanceChanged: @escaping (Bool) -> Void
	) {
		self.applicationCommands = applicationCommands
		self.libraryQueries = libraryQueries
		self.collectorCommands = collectorCommands
		self.persistsWindowState = persistsWindowState
		self.preferences = preferences
		self.wordingContextProvider = wordingContextProvider
		self.onAttendanceChanged = onAttendanceChanged

		let mainWindow = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 1340, height: 820),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		// The content fills the frame under the toolbar, so its minimum is the frame's; a frame minimum
		// of 560 points became a content minimum of 580.
		mainWindow.contentMinSize = NSSize(width: 900, height: 560)
		mainWindow.title = "Schublade"
		mainWindow.toolbarStyle = .unified
		mainWindow.tabbingMode = .disallowed
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
		restoredPlace = preferences.libraryPlace
		restoredPlace?.restore(into: &navigation)
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
			if library.archive == .notConfigured {
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
			display(resolved)
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
		ActivationPolicy.becomeAccessoryUnlessAnotherWindowShows(besides: window)
	}

	private func screen(for content: WindowContent) -> Screen {
		switch content {
		case let .status(presentation):
			.status(presentation)
		case let .connectionForm(purpose):
			.connectionForm(address: purpose.address, cancellable: purpose.cancellable)
		case .libraryWorkspace:
			.libraryWorkspace
		}
	}

	private func display(_ content: WindowContent) {
		switch content {
		case let .status(presentation):
			showWithoutChrome(StatusMessageViewController(presentation: presentation))
		case let .connectionForm(purpose):
			showWithoutChrome(ConnectionFormViewController(
				commands: applicationCommands,
				purpose: purpose,
				onConnected: { [weak self] in self?.endTokenReplacement() },
				onCancel: { [weak self] in self?.endTokenReplacement() }
			))
		case .libraryWorkspace:
			window?.titleVisibility = .visible
			window?.titlebarAppearsTransparent = false
			let workspace = buildWorkspaceController()
			workspaceController = workspace
			workspace.listController.onShownDocumentsChanged = { [weak self] shown in
				guard let self, let presentation = shownWorkspace else {
					return
				}
				window?.subtitle = presentation.windowSubtitle(shownDocuments: shown)
			}
			containerController.display(workspace)
			toolbarController?.track(workspace.splitView)
			window?.toolbar = toolbarController?.toolbar
			window?.makeFirstResponder(workspace.listController.focusTargetView)
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
		switch action {
		case .replaceToken:
			present()
			beginTokenReplacement()
		case let .decideBacklog(folder), let .openFolder(folder):
			show(.folder(folder), selecting: nil)
		}
	}

	/// Shows the window on a destination, such as a document chosen in the menu bar item's menu.
	func show(_ destination: NavigationDestination, selecting document: DocumentIdentifier?) {
		present()
		updateNavigation { navigation in
			navigation.destination = destination
			navigation.searchText = ""
			navigation.selectedDocument = document
		}
	}

	func beginTokenReplacement() {
		guard case let .running(statuses) = latestSituation,
		      case let .configured(origin, _, _, _, _)? = statuses.library?.archive
		else {
			return
		}
		navigation.replacingTokenOrigin = origin
		render(latestSituation)
	}
}

private extension MainWindowController {
	func configureToolbar() {
		toolbarController = WorkspaceToolbarController(
			onNavigateBack: { [weak self] in self?.navigateBack() },
			onSelectOrder: { [weak self] order in self?.setBrowseOrder(order) },
			onSelectReaderTab: { [weak self] tab in self?.workspaceController?.setReaderTab(tab) },
			onSearchTextChanged: { [weak self] query in self?.setSearchText(query) },
			onMoveFocusToList: { [weak self] selectsFirstDocument in
				self?.workspaceController?.moveFocusToList(selectingFirstDocument: selectsFirstDocument)
			},
			shareableItems: { [weak self] in self?.workspaceController?.shareableItems() ?? [] }
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

	/// The pages before the library stand on the bare window, as a welcome does: no toolbar, no
	/// title, and a title bar that lets the page show through.
	func showWithoutChrome(_ page: NSViewController) {
		workspaceController = nil
		window?.toolbar = nil
		window?.titleVisibility = .hidden
		window?.titlebarAppearsTransparent = true
		containerController.display(page)
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

	private func readableArchiveStatus() -> LibraryStatus? {
		guard case let .running(statuses) = latestSituation, let library = statuses.library else {
			return nil
		}
		return Self.libraryReadable(library.archive) ? library : nil
	}

	func endTokenReplacement() {
		guard navigation.replacingTokenOrigin != nil else {
			return
		}
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
			checkRestoredPlace(against: facets)
			render(latestSituation)
		}
	}

	static func libraryReadable(_ archive: ArchiveConnection) -> Bool {
		guard case let .configured(_, _, _, permission, _) = archive else {
			return false
		}
		return permission != .collectOnly
	}
}
