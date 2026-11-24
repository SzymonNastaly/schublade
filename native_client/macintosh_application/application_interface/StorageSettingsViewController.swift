import AppKit
import ApplicationBindings
import ApplicationPresentation
import LibraryPresentation

/// Settings > Storage: the room the downloaded originals take, the most they may take, and Remove
/// Downloaded Originals. An original is downloaded again when it is next opened.
public final class StorageSettingsViewController: NSViewController {
	private let commands: any StorageCommands
	private let preferences: ApplicationPreferences
	private let limit = NSPopUpButton()
	private let held = NSTextField(wrappingLabelWithString: "")
	private let remove = NSButton(title: "Remove Downloaded Originals", target: nil, action: nil)

	public init(commands: any StorageCommands, preferences: ApplicationPreferences) {
		self.commands = commands
		self.preferences = preferences
		super.init(nibName: nil, bundle: nil)
		title = "Storage"
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override public func loadView() {
		limit.addItems(withTitles: MacintoshDevice.wording.storageLimitChoices.map(StorageWording.limitTitle))
		limit.target = self
		limit.action = #selector(limitChosen)
		remove.bezelStyle = .push
		remove.target = self
		remove.action = #selector(removePressed)
		held.font = NSFont.preferredFont(forTextStyle: .body)
		let note = NSTextField(wrappingLabelWithString: "Originals read longest ago go first. Each is downloaded "
			+ "again when it is next opened.")
		note.font = NSFont.preferredFont(forTextStyle: .subheadline)
		note.textColor = .secondaryLabelColor
		view = SettingsPaneLayout.pane([
			.init(label: "Originals:", content: held),
			.init(label: "Keep up to:", content: limit, spacingAbove: 8),
			.init(label: nil, content: note),
			.init(label: nil, content: remove, spacingAbove: 8),
		])
		// A Settings window takes the size of its tab's content.
		preferredContentSize = view.fittingSize
	}

	override public func viewWillAppear() {
		super.viewWillAppear()
		let chosen = MacintoshDevice.wording.storageLimitChoices.firstIndex(of: preferences.originalStorageLimit)
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
			held.stringValue = StorageWording.heldSentence(storage.heldBytes, device: MacintoshDevice.wording)
			remove.isEnabled = storage.heldBytes > 0
		}
	}

	@objc private func limitChosen() {
		preferences.originalStorageLimit = MacintoshDevice.wording.storageLimitChoices[limit.indexOfSelectedItem]
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
