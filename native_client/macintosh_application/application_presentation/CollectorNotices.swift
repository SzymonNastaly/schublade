import ApplicationBindings

/// Which changes of the collector's status deserve a notification: a folder whose survey finished,
/// and a token the archive began to refuse. A first status after launch deserves none, because the
/// window shows what was already waiting.
public enum CollectorNotices {
	public static func arising(
		previous: CollectorStatus?,
		next: CollectorStatus,
		context: WordingContext
	) -> [CollectorNotice] {
		guard let previous else {
			return []
		}
		var notices: [CollectorNotice] = next.folders.compactMap { folder in
			guard case .awaitingDecision = folder.admission,
			      !awaitsDecision(folder.folder.identifier, in: previous)
			else {
				return nil
			}
			let name = context.folderName(folder.folder.root)
			return CollectorNotice(
				identifier: folderNoticeIdentifier(folder.folder.identifier),
				title: "\(name) is ready for your decision",
				body: "Schublade looked through the files already there. Nothing uploads before you decide.",
				action: .decideBacklog(folder.folder.identifier)
			)
		}
		if let reason = suspensionReason(in: next), suspensionReason(in: previous) == nil {
			notices.append(CollectorNotice(
				identifier: tokenNoticeIdentifier,
				title: reason == .credentialRefused
					? "Schublade refused the token"
					: "The token may not upload documents",
				body: "Nothing uploads until you replace the token.",
				action: .replaceToken
			))
		}
		return notices
	}

	/// The identifiers of notifications whose event is over: a folder decided or removed, and a token
	/// no longer refused. Notification Center withdraws them, so a late click never opens a stale page.
	public static func settled(previous: CollectorStatus?, next: CollectorStatus) -> [String] {
		guard let previous else {
			return []
		}
		var identifiers = previous.folders.compactMap { folder -> String? in
			guard awaitsDecision(folder.folder.identifier, in: previous),
			      !awaitsDecision(folder.folder.identifier, in: next)
			else {
				return nil
			}
			return folderNoticeIdentifier(folder.folder.identifier)
		}
		if suspensionReason(in: previous) != nil, suspensionReason(in: next) == nil {
			identifiers.append(tokenNoticeIdentifier)
		}
		return identifiers
	}

	private static let tokenNoticeIdentifier = "token-refused"

	private static func folderNoticeIdentifier(_ folder: FolderIdentifier) -> String {
		"folder-surveyed-\(folder.value)"
	}

	private static func awaitsDecision(_ folder: FolderIdentifier, in status: CollectorStatus) -> Bool {
		status.folders.contains { listed in
			guard listed.folder.identifier == folder, case .awaitingDecision = listed.admission else {
				return false
			}
			return true
		}
	}

	private static func suspensionReason(in status: CollectorStatus) -> SuspensionReason? {
		for item in status.attention {
			if case let .credentialSuspended(reason) = item {
				return reason
			}
		}
		return nil
	}
}
