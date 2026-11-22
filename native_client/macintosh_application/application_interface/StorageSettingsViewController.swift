import AppKit
import ApplicationBindings
import ApplicationPresentation

/// Settings > Storage: the most room for downloaded originals, the room they take, and Remove
/// Downloaded Originals. An original is downloaded again when it is next opened.
final class StorageSettingsViewController: NSViewController {
	private let commands: any StorageCommands
	private let preferences: ApplicationPreferences
	private let limit = NSPopUpButton()
	private let held = NSTextField(labelWithString: "")
	private let remove = NSButton(title: "Remove Downloaded Originals", target: nil, action: nil)

	init(commands: any StorageCommands, preferences: ApplicationPreferences) {
		self.commands = commands
		self.preferences = preferences
		super.init(nibName: nil, bundle: nil)
		title = "Storage"
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func loadView() {
		limit.addItems(withTitles: StorageWording.limitChoices.map(StorageWording.limitTitle))
		limit.target = self
		limit.action = #selector(limitChosen)
		remove.bezelStyle = .rounded
		remove.target = self
		remove.action = #selector(removePressed)
		held.textColor = .secondaryLabelColor
		let limitRow = NSStackView(views: [NSTextField(labelWithString: "Keep downloaded originals up to:"), limit])
		limitRow.spacing = 8
		let note = NSTextField(wrappingLabelWithString: "Originals read longest ago go first. Each is downloaded "
			+ "again when it is next opened.")
		note.textColor = .secondaryLabelColor
		note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		let stack = NSStackView(views: [limitRow, note, held, remove])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.setCustomSpacing(16, after: note)
		stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
		note.widthAnchor.constraint(equalToConstant: 360).isActive = true
		view = stack
		// A Settings window takes the size of its tab's content.
		preferredContentSize = NSSize(width: 440, height: stack.fittingSize.height)
	}

	override func viewWillAppear() {
		super.viewWillAppear()
		let chosen = StorageWording.limitChoices.firstIndex(of: preferences.originalStorageLimit)
		limit.selectItem(at: chosen ?? 1)
		refresh()
	}

	private func refresh() {
		Task {
			guard let storage = try? await commands.originalStorage() else {
				held.stringValue = "Schublade has not started its library."
				remove.isEnabled = false
				return
			}
			held.stringValue = StorageWording.heldSentence(storage.heldBytes)
			remove.isEnabled = storage.heldBytes > 0
		}
	}

	@objc private func limitChosen() {
		preferences.originalStorageLimit = StorageWording.limitChoices[limit.indexOfSelectedItem]
		Task {
			// Each call applies the choice saved when it runs, so quick choices end on the last one.
			try? await commands.setOriginalStorageLimit(preferences.originalStorageLimit)
			refresh()
		}
	}

	@objc private func removePressed() {
		Task {
			try? await commands.removeDownloadedOriginals()
			refresh()
		}
	}
}
