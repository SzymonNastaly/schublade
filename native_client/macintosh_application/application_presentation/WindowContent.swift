import ApplicationBindings
import LibraryPresentation

/// The complete screen the main window renders for the current situation and navigation state.
public enum WindowContent: Equatable, Sendable {
	/// Starting, a start failure, a library fault, or stopped.
	case status(EmptyStatePresentation)
	case connectionForm(ConnectionFormPurpose)
	case libraryWorkspace(LibraryWorkspacePresentation)

	public static func resolve(
		situation: ApplicationSituation,
		navigation: LibraryNavigationState,
		facets: LibraryFacets?,
		context: ApplicationWordingContext
	) -> WindowContent {
		switch situation {
		case .starting:
			return .status(.starting)
		case let .failedToStart(failure):
			return .status(.startFailure(failure))
		case let .running(statuses):
			guard let library = statuses.library else {
				return .status(statuses.libraryFault.map(EmptyStatePresentation.libraryFault) ?? .starting)
			}
			return resolveRunning(
				statuses: statuses,
				library: library,
				navigation: navigation,
				facets: facets,
				context: context
			)
		case .stopped:
			return .status(.stopped)
		}
	}

	private static func resolveRunning(
		statuses: ApplicationStatuses,
		library: LibraryStatus,
		navigation: LibraryNavigationState,
		facets: LibraryFacets?,
		context: ApplicationWordingContext
	) -> WindowContent {
		switch library.archive {
		case .notConfigured:
			return .connectionForm(.welcome)
		case let .configured(origin, _, condition, permission, _):
			let reason = tokenReplacementReason(condition: condition, permission: permission)
			if let replacingOrigin = navigation.replacingTokenOrigin {
				return .connectionForm(.replaceToken(origin: replacingOrigin, reason: reason, cancellable: true))
			}
			let leavesNothingToDo = permission == .collectOnly && statuses.collector == nil
			if leavesNothingToDo {
				return .connectionForm(.replaceToken(origin: origin, reason: reason, cancellable: false))
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

	private static func tokenReplacementReason(
		condition: ConnectionCondition,
		permission: ArchivePermission
	) -> String? {
		if case let .suspended(reason) = condition {
			return switch reason {
			case .credentialRefused: "The archive refused the current token. It may have been revoked."
			case .credentialInsufficient: "The current token no longer permits what this Mac does."
			}
		}
		if permission == .collectOnly {
			return "The current token adds documents but cannot read the archive."
		}
		return nil
	}

	private static func buildWorkspace(
		statuses: ApplicationStatuses,
		navigation: LibraryNavigationState,
		facets: LibraryFacets?,
		context: ApplicationWordingContext
	) -> LibraryWorkspacePresentation {
		guard let library = statuses.library else {
			preconditionFailure("Library workspace requires a library status")
		}
		let sidebar = SidebarPresentation.resolve(statuses: statuses, facets: facets, context: context)
		let detailMode = resolveDetailMode(
			destination: navigation.destination,
			statuses: statuses,
			context: context
		)
		switch navigation.destination {
		case let .library(scope, name):
			return listingWorkspace(
				listing: LibraryScopePresentation.resolve(
					scope: scope,
					name: name,
					searchText: navigation.searchText,
					browseOrder: navigation.browseOrder
				),
				scope: scope,
				detailMode: detailMode,
				sidebar: sidebar,
				indexingNotice: LibraryScopePresentation.textIndexingNotice(
					searchText: navigation.searchText,
					counts: library.counts
				)
			)
		case .needsAttention:
			return pageWorkspace(
				title: "Needs Attention",
				detailMode: detailMode,
				sidebar: sidebar,
				navigation: navigation
			)
		case let .folder(folderIdentifier):
			return pageWorkspace(
				title: folderTitle(folderIdentifier, statuses: statuses, context: context),
				detailMode: detailMode,
				sidebar: sidebar,
				navigation: navigation
			)
		}
	}

	private static func listingWorkspace(
		listing: LibraryScopePresentation,
		scope: LibraryScope,
		detailMode: WorkspaceDetailMode,
		sidebar: SidebarPresentation,
		indexingNotice: String?
	) -> LibraryWorkspacePresentation {
		let showsBackButton = if case .sender = scope {
			true
		} else {
			false
		}
		return LibraryWorkspacePresentation(
			windowTitle: listing.title,
			countsShownDocuments: detailMode == .documents,
			showsBackButton: showsBackButton,
			detailMode: detailMode,
			sidebar: sidebar,
			allowsSortSelection: listing.allowsSortSelection,
			effectiveOrder: listing.effectiveOrder,
			searchAllDocumentsAvailable: listing.searchAllDocumentsAvailable,
			textIndexingNotice: indexingNotice,
			searchPlaceholder: "Search \(listing.title)"
		)
	}

	private static func resolveDetailMode(
		destination: NavigationDestination,
		statuses: ApplicationStatuses,
		context: ApplicationWordingContext
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
			if case .complete = library.copy, library.counts.documents == 0 {
				return .emptyArchive(offersFolders: statuses.collector != nil)
			}
			return .documents
		case .needsAttention:
			let total = statuses.attentionCount(failedDocuments: statuses.library?.counts.documentsFailed ?? 0)
			let summary = total == 0
				? "Nothing needs attention right now."
				: "\(DocumentFormatting.countText(total, singular: "item")) need your attention."
			return .needsAttention(summary: summary)
		case let .folder(folderIdentifier):
			return .folder(folderIdentifier, name: folderTitle(folderIdentifier, statuses: statuses, context: context))
		}
	}

	private static func pageWorkspace(
		title: String,
		detailMode: WorkspaceDetailMode,
		sidebar: SidebarPresentation,
		navigation: LibraryNavigationState
	) -> LibraryWorkspacePresentation {
		LibraryWorkspacePresentation(
			windowTitle: title,
			countsShownDocuments: false,
			showsBackButton: false,
			detailMode: detailMode,
			sidebar: sidebar,
			allowsSortSelection: false,
			effectiveOrder: navigation.browseOrder,
			searchAllDocumentsAvailable: false,
			textIndexingNotice: nil,
			searchPlaceholder: "Search All Documents"
		)
	}

	private static func folderTitle(
		_ folderIdentifier: FolderIdentifier,
		statuses: ApplicationStatuses,
		context: ApplicationWordingContext
	) -> String {
		let folder = statuses.collector?.folders.first { $0.folder.identifier == folderIdentifier }
		return folder.map { context.folderName($0.folder.root) } ?? "Folder"
	}
}
