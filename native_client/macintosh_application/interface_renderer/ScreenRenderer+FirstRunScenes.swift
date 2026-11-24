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
}
