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
				identifier: "folder-surveyed-\(folder.folder.identifier.value)",
				title: "\(name) is ready for your decision",
				body: "Schublade looked through the files already there. Nothing uploads before you decide.",
				action: .decideBacklog(folder.folder.identifier)
			)
		}
		if suspensionReason(in: next) != nil, suspensionReason(in: previous) == nil {
			notices.append(CollectorNotice(
				identifier: "token-refused",
				title: "Schublade refused the token",
				body: "Nothing uploads until you replace the token.",
				action: .replaceToken
			))
		}
		return notices
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
