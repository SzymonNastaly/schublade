import ApplicationBindings
import ApplicationPresentation
import Testing

/// The window before the library: the welcome, the replace form, and a start failure.
struct FirstRunPresentationTests {
	@Test func theWindowWelcomesAFirstArchiveAndReplacesAWorkingTokenWithoutAReason() {
		var unconnected = WindowContentAndSidebarTests.makeStatuses()
		unconnected.library?.archive = .notConfigured
		let welcome = WindowContent.resolve(
			situation: .running(unconnected),
			navigation: LibraryNavigationState(),
			facets: nil,
			context: WindowContentAndSidebarTests.fixedContext()
		)
		#expect(welcome == .connectionForm(.welcome))

		var navigation = LibraryNavigationState()
		navigation.replacingTokenOrigin = "https://archive.example.org"
		let replacing = WindowContent.resolve(
			situation: .running(WindowContentAndSidebarTests.makeStatuses()),
			navigation: navigation,
			facets: nil,
			context: WindowContentAndSidebarTests.fixedContext()
		)
		#expect(replacing == .connectionForm(.replaceToken(
			origin: "https://archive.example.org",
			reason: nil,
			cancellable: true
		)))
	}

	@Test func aStartFailureSaysWhatHappenedAndWhatToDo() {
		let failure = WindowContent.resolve(
			situation: .failedToStart(.DatabaseInUse),
			navigation: LibraryNavigationState(),
			facets: nil,
			context: WindowContentAndSidebarTests.fixedContext()
		)
		#expect(failure == .status(EmptyStatePresentation(
			picture: .symbol("exclamationmark.triangle"),
			title: "Schublade Could Not Start",
			detail: "Another copy of Schublade is already running on this Mac with the same data. "
				+ "Use the running copy or quit it before opening this one.",
			action: nil
		)))
	}
}
