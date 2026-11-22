import AppIntents

/// The phrases that reach Scan Document from Siri and Spotlight without a shortcut set up first.
nonisolated struct ApplicationShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: ScanDocumentIntent(),
			phrases: [
				"Scan a document with \(.applicationName)",
				"Scan a letter with \(.applicationName)",
				"Scan with \(.applicationName)",
				"\(.applicationName) scan",
			],
			shortTitle: "Scan Document",
			systemImageName: "doc.viewfinder"
		)
	}
}
