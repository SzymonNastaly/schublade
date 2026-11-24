import AppKit
import ApplicationBindings
import ApplicationInterface
import ApplicationPresentation

/// Captures offscreen `NSViewController` hierarchies in light and dark appearances to PNG files.
final class ScreenRenderer {
	/// A scene's controller, and what lines its painted chrome up with the laid-out content.
	struct Scene {
		let controller: NSViewController
		var alignChrome: () -> Void = {}
		var accommodate: (CGFloat) -> Void = { _ in }
		/// What the scene shows once it has settled, such as a row under the pointer.
		var afterSettling: () -> Void = {}
	}

	static let windowSize = NSSize(width: 1340, height: 820)
	/// The window's minimum width, at which the inspector gives way.
	static let windowSizeAtMinimumWidth = NSSize(width: 900, height: 820)

	private let outputDirectory: URL
	let fixtures: RendererFixtures

	init(outputDirectory: URL, fixtures: RendererFixtures) {
		self.outputDirectory = outputDirectory
		self.fixtures = fixtures
	}

	func renderAllScreens() async throws {
		try await renderConnectionAndEmptyScreens()
		try await renderListStateScreens()
		try await renderLibraryDocumentScreens()
		try await renderExtractedTextScreens()
		try await renderReaderAndInspectorScreens()
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
		try await renderFirstRunScenes()
		try await renderSettingsScenes()

		try await renderWorkspaceScene(
			name: "library_empty",
			statuses: fixtures.makeStatuses(facets: RendererSampleCatalog.emptyFacets),
			facets: RendererSampleCatalog.emptyFacets,
			navigation: LibraryNavigationState(),
			queries: fixtures.queries.scene(listing: fixtures.emptyListing)
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
	func renderWorkspaceScene(
		name: String,
		statuses: ApplicationStatuses,
		facets: LibraryFacets = RendererSampleCatalog.sampleFacets,
		navigation: LibraryNavigationState,
		queries: RendererLibraryQueries,
		windowSize: NSSize = ScreenRenderer.windowSize,
		writesRowMenus: Bool = false,
		pointedRow: String? = nil,
		copiedRow: String? = nil
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
		var shownWorkspace: LibraryWorkspaceViewController?
		try await renderAppearances(name: name, size: windowSize, queries: queries) {
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
				searchPlaceholder: workspace.searchPlaceholder,
				showsBackButton: workspace.showsBackButton,
				readerTab: navigation.readerTab,
				hasSelectedDocument: navigation.selectedDocument != nil,
				width: windowSize.width
			)
			let host = makeToolbarHost(toolbar: toolbar, contentController: workspaceController, size: windowSize)
			workspaceController.render(workspace: workspace, statuses: statuses, navigation: navigation)
			shownWorkspace = workspaceController
			return Scene(
				controller: host,
				alignChrome: { toolbar.align(to: workspaceController) },
				accommodate: { workspaceController.accommodate(windowWidth: $0) },
				afterSettling: {
					workspaceController.exhibitInspectorRows(underPointer: pointedRow, copied: copiedRow)
				}
			)
		}
		if writesRowMenus, let shownWorkspace {
			try writeRowMenus(of: shownWorkspace, rowCount: Int(queries.shownRows), name: name)
		}
	}

	func renderAppearances(
		name: String,
		size: NSSize = ScreenRenderer.windowSize,
		queries: RendererLibraryQueries?,
		buildScene: () -> Scene
	) async throws {
		for (label, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
			guard let appearance = NSAppearance(named: appearanceName) else {
				continue
			}
			try await capture(
				scene: buildScene(),
				size: size,
				queries: queries,
				appearance: appearance,
				fileURL: outputDirectory.appending(path: "\(name)_\(label).png")
			)
		}
	}

	private func capture(
		scene: Scene,
		size: NSSize,
		queries: RendererLibraryQueries?,
		appearance: NSAppearance,
		fileURL: URL
	) async throws {
		let controller = scene.controller
		if size != Self.windowSize {
			scene.accommodate(size.width)
		}
		let window = NSWindow(
			contentRect: NSRect(origin: .zero, size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.appearance = appearance
		window.contentViewController = controller
		window.setFrame(NSRect(origin: .zero, size: size), display: false)
		controller.view.appearance = appearance
		window.layoutIfNeeded()

		try await settle(queries: queries, layingOut: controller.view)
		scene.afterSettling()
		scene.alignChrome()

		var pngData: Data?
		appearance.performAsCurrentDrawingAppearance {
			controller.view.layoutSubtreeIfNeeded()
			let bounds = controller.view.bounds
			guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: bounds) else {
				return
			}
			controller.view.cacheDisplay(in: bounds, to: bitmap)
			pngData = bitmap.onWindowBackground()?.representation(using: .png, properties: [:])
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

private extension ScreenRenderer {
	/// The list's states: rows on their way and failed, and the empty states of a scope, a search,
	/// and a first copy.
	func renderListStateScreens() async throws {
		try await renderWorkspaceScene(
			name: "library_arriving_and_failed",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(),
			queries: fixtures.queries.scene(listing: fixtures.arrivingAndFailedListing),
			writesRowMenus: true
		)

		try await renderWorkspaceScene(
			name: "library_empty_scope",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(destination: .library(.failed, title: nil)),
			queries: fixtures.queries.scene(listing: fixtures.emptyListing)
		)

		try await renderWorkspaceScene(
			name: "library_search_no_result",
			statuses: fixtures.makeStatuses(),
			navigation: LibraryNavigationState(
				destination: .library(.category(category: CategoryIdentifier(value: "c1")), title: "Invoice"),
				searchText: "Nordbank"
			),
			queries: fixtures.queries.scene(listing: fixtures.emptyListing)
		)

		try await renderWorkspaceScene(
			name: "library_first_fill",
			statuses: fixtures.makeStatuses(
				facets: RendererSampleCatalog.emptyFacets,
				copy: .filling(received: 250, remaining: 1258)
			),
			facets: RendererSampleCatalog.emptyFacets,
			navigation: LibraryNavigationState(),
			queries: fixtures.queries.scene(listing: fixtures.emptyListing)
		)
	}

	/// Each document row's context menu as text: its items in order, with a line for each
	/// separator and a mark for an item that shows no symbol.
	func writeRowMenus(of workspace: LibraryWorkspaceViewController, rowCount: Int, name: String) throws {
		var text = ""
		for row in 0 ..< rowCount {
			let items = workspace.documentRowMenu(atRow: row).items
			guard !items.isEmpty else {
				continue
			}
			text += "Row \(row)\n"
			for item in items {
				text += item.isSeparatorItem ? "  ----\n" : "  \(item.title)\(item.image == nil ? " (no symbol)" : "")\n"
			}
			text += "\n"
		}
		try text.write(to: outputDirectory.appending(path: "\(name)_row_menus.txt"), atomically: true, encoding: .utf8)
	}

	func makeToolbarHost(
		toolbar: PaintedToolbarView,
		contentController: NSViewController,
		size: NSSize
	) -> NSViewController {
		let container = NSViewController()
		let root = NSView(frame: NSRect(origin: .zero, size: size))
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
}

private extension NSBitmapImageRep {
	/// Draws a capture over the window's background, which a window draws behind its content view and
	/// which `cacheDisplay` leaves out, so a screen without a background of its own keeps its colours.
	func onWindowBackground() -> NSBitmapImageRep? {
		guard let composed = NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: pixelsWide,
			pixelsHigh: pixelsHigh,
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		), let context = NSGraphicsContext(bitmapImageRep: composed) else {
			return nil
		}
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = context
		let pixels = NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
		NSColor.windowBackgroundColor.setFill()
		pixels.fill()
		draw(in: pixels, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
		NSGraphicsContext.restoreGraphicsState()
		composed.size = size
		return composed
	}
}
