import AppKit
import ApplicationBindings

/// The menu bar item: a fixed glyph, a situation line, an Open Schublade action, and Quit.
final class StatusItemController {
	let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
	private let situationLine = NSMenuItem()
	var onOpenWindow: (() -> Void)?

	init() {
		item.button?.image = NSImage(
			systemSymbolName: "tray.full",
			accessibilityDescription: NSRunningApplication.current.localizedName
		)
		let menu = NSMenu()
		menu.addItem(situationLine)
		menu.addItem(.separator())

		let openItem = NSMenuItem(title: "Open Schublade", action: #selector(openWindow), keyEquivalent: "")
		openItem.target = self
		menu.addItem(openItem)

		menu.addItem(.separator())
		menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
		item.menu = menu
	}

	func render(_ situation: ApplicationSituation) {
		situationLine.title = switch situation {
		case .starting:
			"Starting"
		case let .failedToStart(failure):
			ApplicationFailureWording.startFailureSentence(failure)
		case let .running(statuses):
			Self.runningSentence(statuses)
		case .stopped:
			"Stopped"
		}
	}

	@objc private func openWindow() {
		onOpenWindow?()
	}

	private static func runningSentence(_ statuses: ApplicationStatuses) -> String {
		if let fault = statuses.libraryFault ?? statuses.collectorFault {
			return ApplicationFailureWording.faultSentence(fault)
		}
		guard let library = statuses.library else {
			return "Starting"
		}
		switch library.archive {
		case .notConfigured:
			return "Not connected"
		case let .configured(_, host, _, permission, _):
			if permission == .collectOnly {
				return "Collecting into \(host)"
			}
			let documents = library.counts.documents
			let documentText = documents == 1 ? "1 document" : "\(documents) documents"
			return "\(host) · \(documentText)"
		}
	}
}
