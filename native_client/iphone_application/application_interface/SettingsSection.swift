import ApplicationBindings
import Foundation
import LibraryPresentation
import SubmissionQueue
import UIKit

/// One row of Settings.
enum SettingsRow: Equatable {
	/// The archive's host, with the status line and its symbol.
	case archive(host: String, status: StatusLinePresentation)
	case openArchiveInBrowser(URL)
	case replaceToken
	/// The most room the downloaded originals may take, which a menu chooses.
	case keepOriginals(limit: UInt64?)
	/// Removes the downloaded originals, while any are downloaded.
	case removeDownloadedOriginals(available: Bool)
	case scanShortcut(ScanShortcut)

	var selectable: Bool {
		switch self {
		case .openArchiveInBrowser, .replaceToken: true
		case let .removeDownloadedOriginals(available): available
		case .archive, .keepOriginals, .scanShortcut: false
		}
	}
}

/// A way to scan without opening Schublade, which the application cannot show from inside.
struct ScanShortcut: Equatable {
	let symbolName: String
	let title: String
	let detail: String

	static let all = [
		ScanShortcut(
			symbolName: "apps.iphone",
			title: "Home Screen",
			detail: "Touch and hold the Schublade icon, then choose Scan Document."
		),
		ScanShortcut(
			symbolName: "switch.2",
			title: "Control Center and Lock Screen",
			detail: "Add the Scan Document control."
		),
		ScanShortcut(
			symbolName: "button.horizontal.top.press",
			title: "Action Button",
			detail: "In the Settings app, choose Shortcut, then Scan Document."
		),
		ScanShortcut(symbolName: "mic", title: "Siri", detail: "Say \u{201C}Scan with Schublade\u{201D}."),
	]
}

/// What sits under a section of Settings.
enum SettingsFooter: Equatable {
	case text(String)
	/// The icon, the name, and the version, under the last section.
	case about
}

/// A section of Settings: the archive, the storage of originals, the ways to scan from outside the
/// application while the token can send, and the about footer in a section without rows.
struct SettingsSection: Equatable {
	let header: String?
	let footer: SettingsFooter?
	let rows: [SettingsRow]

	/// The sections while an archive is connected, and none otherwise. `storage` is nil until the copy
	/// has answered how much room the originals take.
	static func sections(
		of library: LibraryStatus,
		limit: UInt64?,
		storage: OriginalStorage?,
		context: WordingContext
	) -> [SettingsSection] {
		guard case let .configured(origin, host, _, _, restricted) = library.archive else {
			return []
		}
		let status = StatusLinePresentation.resolve(library: library, fault: nil, uploadingFiles: 0, context: context)
		var archiveRows: [SettingsRow] = [.archive(host: host, status: status)]
		if let address = URL(string: origin) {
			archiveRows.append(.openArchiveInBrowser(address))
		}
		archiveRows.append(.replaceToken)
		let storageNote = "Originals read longest ago go first. Each is downloaded again when you open it."
		let scanning = SettingsSection(
			header: "Scan Without Opening Schublade",
			footer: nil,
			rows: ScanShortcut.all.map(SettingsRow.scanShortcut)
		)
		let about = SettingsSection(header: nil, footer: .about, rows: [])
		return [
			SettingsSection(
				header: "Archive",
				footer: .text(restricted
					? ConnectedArchive.restrictionSentence
					: "This iPhone reads your archive and sends documents to it."),
				rows: archiveRows
			),
			SettingsSection(
				header: "Storage",
				footer: .text(storage.map {
					"\(StorageWording.heldSentence($0.heldBytes, device: IphoneDevice.wording)) \(storageNote)"
				} ?? storageNote),
				rows: [
					.keepOriginals(limit: limit),
					.removeDownloadedOriginals(available: (storage?.heldBytes ?? 0) > 0),
				]
			),
		] + (restricted ? [] : [scanning]) + [about]
	}
}

extension SettingsRow {
	/// Draws the row. Keep Originals offers the limits in a menu and passes the chosen one on.
	func configure(_ cell: UICollectionViewListCell, choosingLimit: @escaping (UInt64?) -> Void) {
		var accessories: [UICellAccessory] = []
		var content: UIListContentConfiguration
		switch self {
		case let .archive(host, status):
			content = .subtitleCell()
			content.image = UIImage(systemName: status.symbolName)
			content.imageProperties.tintColor = status.tone == .attention ? InterfacePalette
				.attentionText : .secondaryLabel
			content.text = host
			content.secondaryText = status.text
			Self.detailStyle(&content)
		case .openArchiveInBrowser:
			content = .cell()
			content.image = UIImage(systemName: "safari")
			content.text = "Open Archive in Browser"
		case .replaceToken:
			content = .cell()
			content.image = UIImage(systemName: "key")
			content.text = "Replace Token"
			accessories = [.disclosureIndicator()]
		case let .keepOriginals(limit):
			content = .valueCell()
			content.text = "Keep Originals"
			content.secondaryText = StorageWording.limitTitle(limit)
			let menu = UIMenu(
				options: .singleSelection,
				children: IphoneDevice.wording.storageLimitChoices.map { choice in
					UIAction(title: StorageWording.limitTitle(choice), state: choice == limit ? .on : .off) { _ in
						choosingLimit(choice)
					}
				}
			)
			accessories = [.popUpMenu(menu)]
		case let .removeDownloadedOriginals(available):
			content = .cell()
			content.text = "Remove Downloaded Originals"
			content.textProperties.color = available ? .tintColor : .tertiaryLabel
		case let .scanShortcut(shortcut):
			content = .subtitleCell()
			content.image = UIImage(systemName: shortcut.symbolName)
			content.text = shortcut.title
			content.secondaryText = shortcut.detail
			Self.detailStyle(&content)
		}
		cell.contentConfiguration = content
		cell.accessories = accessories
		cell.accessibilityTraits = selectable ? .button : .none
		cell.accessibilityIdentifier = accessibilityIdentifier
	}

	private var accessibilityIdentifier: String? {
		switch self {
		case .archive: "settings.archive"
		case .openArchiveInBrowser: "settings.openArchive"
		case .replaceToken: "settings.replaceToken"
		case .keepOriginals: "settings.keepOriginals"
		case .removeDownloadedOriginals: "settings.removeDownloadedOriginals"
		case .scanShortcut: nil
		}
	}

	private static func detailStyle(_ content: inout UIListContentConfiguration) {
		content.secondaryTextProperties.color = .secondaryLabel
		content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
		content.textToSecondaryTextVerticalPadding = 3
	}
}
