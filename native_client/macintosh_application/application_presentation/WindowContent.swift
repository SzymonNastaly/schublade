import ApplicationBindings

/// The complete screen the main window renders for the current situation and navigation state.
public enum WindowContent: Equatable, Sendable {
	case starting(message: String)
	case failedToStart(StartFailureWording)
	case fault(message: String)
	case connectionForm(initialAddress: String?, instruction: String?, cancellable: Bool)
	case libraryWorkspace(LibraryWorkspacePresentation)
	case stopped(message: String)

	public static func resolve(
		situation: ApplicationSituation,
		navigation: LibraryNavigationState,
		facets: LibraryFacets?,
		context: WordingContext
	) -> WindowContent {
		switch situation {
		case .starting:
			return .starting(message: "Starting Schublade…")
		case let .failedToStart(failure):
			return .failedToStart(ApplicationFailureWording.startFailureWording(failure))
		case let .running(statuses):
			guard let library = statuses.library else {
				if let fault = statuses.libraryFault {
					return .fault(message: ApplicationFailureWording.faultSentence(fault))
				}
				return .starting(message: "Starting Schublade…")
			}
			return resolveRunning(
				statuses: statuses,
				library: library,
				navigation: navigation,
				facets: facets,
				context: context
			)
		case .stopped:
			return .stopped(message: "Schublade stopped.")
		}
	}

	private static func resolveRunning(
		statuses: ApplicationStatuses,
		library: LibraryStatus,
		navigation: LibraryNavigationState,
		facets: LibraryFacets?,
		context: WordingContext
	) -> WindowContent {
		switch library.archive {
		case .notConfigured:
			return .connectionForm(initialAddress: nil, instruction: nil, cancellable: false)
		case let .configured(origin, _, condition, permission, _):
			if let replacingOrigin = navigation.replacingTokenOrigin {
				let instruction = tokenReplacementInstruction(condition: condition, permission: permission)
				return .connectionForm(initialAddress: replacingOrigin, instruction: instruction, cancellable: true)
			}
			if permission == .collectOnly, statuses.collector == nil {
				let guidance = "This token can only add documents and cannot read the archive. "
					+ "Paste a token with read permission from Settings."
				return .connectionForm(initialAddress: origin, instruction: guidance, cancellable: false)
			}
			let workspace = buildWorkspace(
				statuses: statuses,
				navigation: navigation,
				facets: facets,
				context: context
			)
			return .libraryWorkspace(workspace)
		}
	}

	private static func tokenReplacementInstruction(
		condition: ConnectionCondition,
		permission: ArchivePermission
	) -> String {
		if permission == .collectOnly {
			return "This token can only add documents and cannot read the archive. "
				+ "Paste a token with read permission from Settings."
		}
		if case .suspended = condition {
			return "Schublade refused the current token. Paste a new API token from Settings."
		}
		return "Paste a new API token from Settings."
	}

	private static func buildWorkspace(
		statuses: ApplicationStatuses,
		navigation: LibraryNavigationState,
		facets: LibraryFacets?,
		context: WordingContext
	) -> LibraryWorkspacePresentation {
		guard let library = statuses.library else {
			preconditionFailure("Library workspace requires a library status")
		}
		let sidebar = SidebarPresentation.resolve(statuses: statuses, facets: facets, context: context)
		let (title, showsBackButton) = headerTitle(
			destination: navigation.destination,
			statuses: statuses,
			context: context
		)
		let detailMode = resolveDetailMode(
			destination: navigation.destination,
			statuses: statuses,
			context: context
		)
		let isSearching = !navigation.trimmedSearchText.isEmpty
		let effectiveOrder = effectiveListingOrder(for: navigation.destination, preferred: navigation.browseOrder)
		let countsShownDocuments = if detailMode == .documents, case .library = navigation.destination {
			true
		} else {
			false
		}
		return LibraryWorkspacePresentation(
			windowTitle: title,
			countsShownDocuments: countsShownDocuments,
			showsBackButton: showsBackButton,
			detailMode: detailMode,
			sidebar: sidebar,
			allowsSortSelection: allowsSort(for: navigation.destination, isSearching: isSearching),
			effectiveOrder: effectiveOrder,
			searchAllDocumentsAvailable: canSearchAllDocuments(for: navigation.destination, isSearching: isSearching),
			textIndexingNotice: indexingNotice(
				destination: navigation.destination,
				isSearching: isSearching,
				counts: library.counts
			)
		)
	}

	private static func effectiveListingOrder(
		for destination: NavigationDestination,
		preferred: ListingOrder
	) -> ListingOrder {
		if case .library(.recentlyAdded, _) = destination {
			return .addition
		}
		return preferred
	}

	private static func allowsSort(for destination: NavigationDestination, isSearching: Bool) -> Bool {
		guard !isSearching, case let .library(scope, _) = destination else {
			return false
		}
		return scope != .recentlyAdded
	}

	private static func canSearchAllDocuments(for destination: NavigationDestination, isSearching: Bool) -> Bool {
		guard isSearching, case let .library(scope, _) = destination else {
			return false
		}
		return scope != .allDocuments
	}

	private static func resolveDetailMode(
		destination: NavigationDestination,
		statuses: ApplicationStatuses,
		context: WordingContext
	) -> WorkspaceDetailMode {
		switch destination {
		case .library:
			guard let library = statuses.library,
			      case let .configured(_, host, condition, permission, _) = library.archive
			else {
				return .documents
			}
			if permission == .collectOnly {
				return .tokenCannotRead(
					message: "This token can only add documents into \(host) and cannot read the archive. "
						+ "Paste a token with read permission from Settings."
				)
			}
			if case .archiveOutdated = condition {
				return .archiveOutdated(message: "Update your archive to use the library.")
			}
			return .documents
		case .needsAttention:
			let total = statuses.attentionCount(failedDocuments: statuses.library?.counts.documentsFailed ?? 0)
			let summary = total == 0
				? "Nothing needs attention right now."
				: "\(DocumentFormatting.countText(total, singular: "item")) need your attention."
			return .needsAttention(summary: summary)
		case let .folder(folderIdentifier):
			let folder = statuses.collector?.folders.first { $0.folder.identifier == folderIdentifier }
			let name = folder.map { context.folderName($0.folder.root) } ?? "Folder"
			return .folder(folderIdentifier, name: name)
		}
	}

	private static func headerTitle(
		destination: NavigationDestination,
		statuses: ApplicationStatuses,
		context: WordingContext
	) -> (String, Bool) {
		switch destination {
		case let .library(scope, title):
			return switch scope {
			case .allDocuments:
				("All Documents", false)
			case .recentlyAdded:
				("Recently Added", false)
			case .inIngestion:
				("Arriving", false)
			case .failed:
				("Failed Documents", false)
			case .household:
				("Household", false)
			case .member, .category, .tag:
				(title ?? "Schublade", false)
			case .sender:
				(title ?? "Sender", true)
			}
		case .needsAttention:
			return ("Needs Attention", false)
		case let .folder(folderIdentifier):
			let folder = statuses.collector?.folders.first { $0.folder.identifier == folderIdentifier }
			return (folder.map { context.folderName($0.folder.root) } ?? "Folder", false)
		}
	}

	private static func indexingNotice(
		destination: NavigationDestination,
		isSearching: Bool,
		counts: LibraryCounts
	) -> String? {
		guard case .library = destination, isSearching, counts.documentsAwaitingText > 0, counts.documents > 0 else {
			return nil
		}
		let total = counts.documents
		let ready = total > counts.documentsAwaitingText ? total - counts.documentsAwaitingText : 0
		return "Searching the text of \(DocumentFormatting.groupedNumber(ready)) of "
			+ "\(DocumentFormatting.groupedNumber(total)) documents"
	}
}
