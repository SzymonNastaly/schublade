import ApplicationBindings

/// A command of a document row's context menu.
public enum DocumentRowCommand: Equatable, Sendable {
	case openOriginal
	case quickLook
	case share
	case copy
	case exportOriginal
	/// Shows the documents of the sender the row names.
	case moreFromSender(name: String)
	case openInBrowser

	public var title: String {
		switch self {
		case .openOriginal: "Open Original"
		case .quickLook: "Quick Look"
		case .share: "Share"
		case .copy: "Copy"
		case .exportOriginal: "Export Original…"
		case let .moreFromSender(name): "More from \(name)"
		case .openInBrowser: "Open in Browser"
		}
	}

	public var symbolName: String {
		switch self {
		case .openOriginal: "arrow.up.forward.app"
		case .quickLook: "eye"
		case .share: "square.and.arrow.up"
		case .copy: "doc.on.doc"
		case .exportOriginal: "square.and.arrow.down"
		case .moreFromSender: "building.2"
		case .openInBrowser: "safari"
		}
	}

	/// The commands that apply to a row, in the menu's order, with a separator before each group.
	/// The original's commands need an original: an archived document has one, and a document in
	/// ingestion or failed has one once the archive recorded its content. An email still awaiting
	/// its rendering has none.
	public static func groups(for row: DocumentRow) -> [[DocumentRowCommand]] {
		let holdsOriginal = if case .archived = row.condition {
			true
		} else {
			row.contentKnown
		}
		var groups: [[DocumentRowCommand]] = []
		if holdsOriginal {
			groups.append([.openOriginal, .quickLook])
			groups.append([.share, .copy, .exportOriginal])
		}
		if let sender = row.senderName, !sender.isEmpty {
			groups.append([.moreFromSender(name: sender)])
		}
		groups.append([.openInBrowser])
		return groups
	}
}
