import AppKit

/// The menu bar item: a fixed glyph, and a menu with one line for the situation and Quit.
final class StatusItemController {
	let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
	private let situationLine = NSMenuItem()

	init() {
		item.button?.image = NSImage(
			systemSymbolName: "tray.full",
			accessibilityDescription: NSRunningApplication.current.localizedName
		)
		let menu = NSMenu()
		menu.addItem(situationLine)
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
		item.menu = menu
	}

	func render(_ situation: CollectorSituation) {
		situationLine.title = switch situation {
		case .starting: "Starting"
		case let .failedToStart(failure): "Failed to start: \(failure)"
		case let .running(status): "Running at revision \(status.revision)"
		case .stopped: "Stopped"
		}
	}
}
