import AppKit
import ApplicationInterface
import ApplicationPresentation

extension ScreenRenderer {
	/// The welcome, a refusal on it, the replace form, and a start failure.
	func renderFirstRunScenes() async throws {
		try await renderAppearances(name: "welcome", queries: nil) {
			Scene(controller: ConnectionFormViewController(commands: RendererApplicationCommands(), purpose: .welcome))
		}
		try await renderAppearances(name: "welcome_refused", queries: nil) {
			let form = ConnectionFormViewController(commands: RendererApplicationCommands(), purpose: .welcome)
			return Scene(controller: form, afterSettling: {
				form.exhibitRefusal(address: "https://archive.example.org", refusal: .TokenRefused)
			})
		}
		try await renderAppearances(name: "replace_token", queries: nil) {
			Scene(controller: ConnectionFormViewController(
				commands: RendererApplicationCommands(),
				purpose: .replaceToken(
					origin: "https://archive.example.org",
					reason: "The archive refused the current token. It may have been revoked.",
					cancellable: true
				)
			))
		}
		try await renderAppearances(name: "start_failure", queries: nil) {
			Scene(controller: StatusMessageViewController(presentation: .startFailure(.DatabaseInUse)))
		}
	}

	/// Each Settings pane at the size the window takes for it, without the window's tabs.
	func renderSettingsScenes() async throws {
		let panes: [(String, () -> NSViewController)] = [
			("settings_general", {
				GeneralSettingsViewController(
					loginItem: LoginItem(isInert: true),
					statusItem: RendererStatusItemVisibility()
				)
			}),
			("settings_archive", { [fixtures] in
				let archive = ArchiveSettingsViewController(onReplaceToken: {})
				archive.render(fixtures.makeStatuses(), context: fixtures.context)
				return archive
			}),
			("settings_storage", {
				StorageSettingsViewController(
					commands: RendererStorageCommands(),
					preferences: ApplicationPreferences(isolated: true)
				)
			}),
		]
		for (name, makePane) in panes {
			let sizingPane = makePane()
			sizingPane.loadViewIfNeeded()
			try await renderAppearances(name: name, size: sizingPane.preferredContentSize, queries: nil) {
				let pane = makePane()
				// An offscreen window never appears, so the pane reads its state as it would.
				pane.viewWillAppear()
				return Scene(controller: pane)
			}
		}
	}
}
