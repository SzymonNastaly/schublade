import AppIntents
import ScanRequest

/// Opens Schublade with the document camera. Shortcuts, Siri, and the Action button run it, and so do
/// the Control Center and Lock Screen controls, whose extension compiles this file as well; the
/// system performs it in the application, which it opens.
nonisolated struct ScanDocumentIntent: AppIntent {
	static let title: LocalizedStringResource = "Scan Document"
	static let description =
		IntentDescription("Opens Schublade with the document camera, to send a letter to your archive.")
	static let openAppWhenRun = true

	@MainActor
	func perform() async throws -> some IntentResult {
		ScanRequestCenter.shared.request()
		return .result()
	}
}
