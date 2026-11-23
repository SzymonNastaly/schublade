import AppKit
import ApplicationBindings
import ApplicationInterface
import ApplicationPresentation

/// Captures offscreen `NSViewController` hierarchies in light and dark appearances to PNG files.
final class ScreenRenderer {
	private static let windowSize = NSSize(width: 1340, height: 820)

	private let outputDirectory: URL
	private let fixtures: RendererFixtures

	init(outputDirectory: URL, fixtures: RendererFixtures) {
		self.outputDirectory = outputDirectory
		self.fixtures = fixtures
	}

	func renderAllScreens() async throws {
		try await renderConnectionAndEmptyScreens()
		try await renderLibraryDocumentScreens()
		try await renderLibraryStatusScreens()
		for scene in CollectorScenes.all(fixtures: fixtures) {
			try await renderWorkspaceScene(
				name: scene.name,
				statuses: scene.statuses,
				facets: scene.facets,
				navigation: scene.navigation,
				queries: fixtures.queries.scene(listing: fixtures.sampleListing)
			)
		}
	}

	private func renderConnectionAndEmptyScreens() async throws {
		try await renderAppearances(name: "connection_form", queries: nil) {
			ConnectionFormViewController(commands: RendererApplicationCommands())
		}

		try await renderWorkspaceScene(
			name: "library_empty",
			statuses: fixtures.makeStatuses(facets: RendererSampleCatalog.emptyFacets),
			facets: RendererSampleCatalog.emptyFacets,
			navigation: LibraryNavigationState(),
			queries: fixtures.queries.scene(listing: fixtures.emptyListing)
		)
	}

	private func renderLibraryDocumentScreens() async throws {
		try await renderWorkspaceScene(
			name: "library_document_pdf",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.allDocuments, title: nil),
				selectedDocument: fixtures.invoiceIdentifier,
				readerTab: .original,
				inspectorVisible: true
			),
			queries: fixtures.queries.scene(listing: fixtures.sampleListing)
		)

		try await renderWorkspaceScene(
			name: "library_document_image",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.allDocuments, title: nil),
				selectedDocument: fixtures.receiptIdentifier,
				readerTab: .original,
				inspectorVisible: true
			),
			queries: fixtures.queries.scene(listing: fixtures.sampleListing)
		)

		try await renderWorkspaceScene(
			name: "library_search_text",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.category(category: CategoryIdentifier(value: "c1")), title: "Invoice"),
				searchText: "Haftpflichtversicherung",
				selectedDocument: fixtures.invoiceIdentifier,
				readerTab: .text,
				inspectorVisible: true
			),
			queries: fixtures.queries.scene(listing: fixtures.searchListing)
		)
	}

	private func renderLibraryStatusScreens() async throws {
		try await renderWorkspaceScene(
			name: "library_offline_missing_original",
			statuses: fixtures.makeStatuses(condition: .unreachable(
				since: fixtures.context.library.now,
				nextAttemptAt: fixtures.context.library.now.addingTimeInterval(60)
			)),
			navigation: LibraryNavigationState(
				destination: .library(.allDocuments, title: nil),
				selectedDocument: fixtures.invoiceIdentifier,
				readerTab: .original,
				inspectorVisible: true
			),
			queries: fixtures.queries.scene(listing: fixtures.sampleListing, originalRefusal: .ArchiveUnreachable)
		)

		try await renderWorkspaceScene(
			name: "library_archive_outdated",
			statuses: fixtures.makeStatuses(condition: .archiveOutdated),
			navigation: LibraryNavigationState(),
			queries: fixtures.queries.scene(listing: fixtures.sampleListing)
		)
	}

	/// Builds the real workspace over the scene's queries, lets it load as it does in the window,
	/// and captures it once every load has settled.
	private func renderWorkspaceScene(
		name: String,
		statuses: ApplicationStatuses,
		facets: LibraryFacets = RendererSampleCatalog.sampleFacets,
		navigation: LibraryNavigationState,
		queries: RendererLibraryQueries
	) async throws {
		let context = fixtures.context
		let content = WindowContent.resolve(
			situation: .running(statuses),
			navigation: navigation,
			facets: facets,
			context: context
		)
		guard case let .libraryWorkspace(workspace) = content else {
			return
		}
		try await renderAppearances(name: name, queries: queries) {
			let workspaceController = LibraryWorkspaceViewController(
				queries: queries,
				collectorCommands: RendererCollectorCommands(),
				renderMode: .offscreenSnapshot,
				persistsState: false,
				wordingContextProvider: { context },
				onNavigationChange: { _ in },
				onReplaceToken: {},
				onFocusSearch: {}
			)
			let toolbar = PaintedToolbarView(
				title: workspace.windowTitle,
				subtitle: workspace.windowSubtitle(shownDocuments: Int(queries.shownDocuments)),
				searchText: navigation.searchText,
				showsBackButton: workspace.showsBackButton,
				width: Self.windowSize.width
			)
			let host = makeToolbarHost(toolbar: toolbar, contentController: workspaceController)
			workspaceController.render(workspace: workspace, statuses: statuses, navigation: navigation)
			return host
		}
	}

	private func makeToolbarHost(
		toolbar: PaintedToolbarView,
		contentController: NSViewController
	) -> NSViewController {
		let container = NSViewController()
		let root = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
		container.view = root
		container.addChild(contentController)

		toolbar.translatesAutoresizingMaskIntoConstraints = false
		contentController.view.translatesAutoresizingMaskIntoConstraints = false
		root.addSubview(toolbar)
		root.addSubview(contentController.view)

		NSLayoutConstraint.activate([
			toolbar.topAnchor.constraint(equalTo: root.topAnchor),
			toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
			toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
			contentController.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
			contentController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
			contentController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
			contentController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
		])
		return container
	}

	private func renderAppearances(
		name: String,
		queries: RendererLibraryQueries?,
		buildController: () -> NSViewController
	) async throws {
		for (label, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
			guard let appearance = NSAppearance(named: appearanceName) else {
				continue
			}
			let controller = buildController()
			try await capture(
				controller: controller,
				queries: queries,
				appearance: appearance,
				fileURL: outputDirectory.appending(path: "\(name)_\(label).png")
			)
		}
	}

	private func capture(
		controller: NSViewController,
		queries: RendererLibraryQueries?,
		appearance: NSAppearance,
		fileURL: URL
	) async throws {
		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: Self.windowSize),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.appearance = appearance
		window.contentViewController = controller
		window.setFrame(NSRect(origin: .zero, size: Self.windowSize), display: false)
		controller.view.appearance = appearance
		window.layoutIfNeeded()

		try await settle(queries: queries, layingOut: controller.view)

		var pngData: Data?
		appearance.performAsCurrentDrawingAppearance {
			controller.view.layoutSubtreeIfNeeded()
			let bounds = controller.view.bounds
			guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: bounds) else {
				return
			}
			controller.view.cacheDisplay(in: bounds, to: bitmap)
			pngData = bitmap.representation(using: .png, properties: [:])
		}

		guard let pngData else {
			throw CocoaError(.fileWriteUnknown)
		}
		try pngData.write(to: fileURL)
		window.orderOut(nil)
	}

	/// Waits until no query has been asked or answered for 300 ms, so the listing, the detail, the
	/// original, the text, and the pictures, each decoded after its answer, are on screen.
	private func settle(queries: RendererLibraryQueries?, layingOut view: NSView) async throws {
		let deadline = ContinuousClock.now + .seconds(10)
		var quietSince = ContinuousClock.now
		var callsSeen = queries?.callsStarted ?? 0
		while ContinuousClock.now - quietSince < .milliseconds(300) {
			guard ContinuousClock.now < deadline else {
				throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "A scene never settled"])
			}
			try await Task.sleep(for: .milliseconds(20))
			view.layoutSubtreeIfNeeded()
			let calls = queries?.callsStarted ?? 0
			if calls != callsSeen || (queries?.callsInFlight ?? 0) > 0 {
				callsSeen = calls
				quietSince = ContinuousClock.now
			}
		}
	}
}
