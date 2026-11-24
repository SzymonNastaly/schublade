import ApplicationBindings
import LibraryPresentation

/// The sidebar sections and status line derived from the latest application statuses and facets.
public struct SidebarPresentation: Equatable, Sendable {
	/// The section of the folders on this Mac, whose heading offers Add Folder….
	public static let foldersSectionIdentifier = "folders"

	public let sections: [SidebarSectionPresentation]
	public let statusLine: StatusLinePresentation

	public init(sections: [SidebarSectionPresentation], statusLine: StatusLinePresentation) {
		self.sections = sections
		self.statusLine = statusLine
	}

	public static func resolve(
		statuses: ApplicationStatuses,
		facets: LibraryFacets?,
		context: ApplicationWordingContext
	) -> SidebarPresentation {
		var sections = [librarySection(statuses: statuses, facets: facets)]
		if let people = peopleSection(facets: facets) {
			sections.append(people)
		}
		if let categories = taxonomySection(
			identifier: "categories",
			title: "Categories",
			symbolName: "folder",
			counts: facets?.categories ?? [],
			prefix: "category"
		) {
			sections.append(categories)
		}
		if let tags = taxonomySection(
			identifier: "tags",
			title: "Tags",
			symbolName: "tag",
			counts: facets?.tags ?? [],
			prefix: "tag"
		) {
			sections.append(tags)
		}
		if let folders = foldersSection(collector: statuses.collector, context: context) {
			sections.append(folders)
		}
		return SidebarPresentation(
			sections: sections,
			statusLine: StatusLinePresentation.resolve(statuses: statuses, context: context)
		)
	}

	private static func librarySection(
		statuses: ApplicationStatuses,
		facets: LibraryFacets?
	) -> SidebarSectionPresentation {
		let totalDocuments = facets?.documents ?? statuses.library?.counts.documents ?? 0
		let inIngestion = facets?.documentsInIngestion ?? statuses.library?.counts.documentsInIngestion ?? 0
		let failed = facets?.documentsFailed ?? statuses.library?.counts.documentsFailed ?? 0
		let attentionCount = statuses.attentionCount(failedDocuments: failed)

		var items: [SidebarItemPresentation] = [
			SidebarItemPresentation(
				identifier: "library.allDocuments",
				title: "All Documents",
				symbolName: "tray.full",
				accessory: totalDocuments > 0 ? .count(DocumentFormatting.groupedNumber(totalDocuments)) : .none,
				kind: .destination(.library(.allDocuments, title: nil))
			),
			SidebarItemPresentation(
				identifier: "library.recentlyAdded",
				title: "Recently Added",
				symbolName: "clock",
				accessory: .none,
				kind: .destination(.library(.recentlyAdded, title: nil))
			),
		]
		if inIngestion > 0 {
			items.append(SidebarItemPresentation(
				identifier: "library.arriving",
				title: "Arriving",
				symbolName: "arrow.down.doc",
				accessory: .count(DocumentFormatting.groupedNumber(inIngestion)),
				kind: .destination(.library(.inIngestion, title: nil))
			))
		}
		if attentionCount > 0 {
			items.append(SidebarItemPresentation(
				identifier: "library.needsAttention",
				title: "Needs Attention",
				symbolName: "exclamationmark.triangle",
				accessory: .count(DocumentFormatting.groupedNumber(attentionCount)),
				kind: .destination(.needsAttention)
			))
		}
		return SidebarSectionPresentation(identifier: "library", title: "Library", items: items)
	}

	private static func peopleSection(facets: LibraryFacets?) -> SidebarSectionPresentation? {
		guard let facets, facets.householdDocuments > 0 || !facets.members.isEmpty else {
			return nil
		}
		var items: [SidebarItemPresentation] = [
			SidebarItemPresentation(
				identifier: "person.household",
				title: "Household",
				symbolName: "house",
				accessory: facets.householdDocuments > 0
					? .count(DocumentFormatting.groupedNumber(facets.householdDocuments))
					: .none,
				kind: .destination(.library(.household, title: "Household"))
			),
		]
		for entry in facets.members {
			guard case let .member(memberIdentifier) = entry.scope.scope else {
				continue
			}
			items.append(SidebarItemPresentation(
				identifier: "person.member.\(memberIdentifier.value)",
				title: entry.scope.name,
				symbolName: "person",
				accessory: entry.documents > 0 ? .count(DocumentFormatting.groupedNumber(entry.documents)) : .none,
				kind: .destination(.library(entry.scope.scope, title: entry.scope.name))
			))
		}
		return SidebarSectionPresentation(identifier: "people", title: "People", items: items)
	}

	private static func taxonomySection(
		identifier: String,
		title: String,
		symbolName: String,
		counts: [ScopeCount],
		prefix: String
	) -> SidebarSectionPresentation? {
		let items = counts.compactMap { entry -> SidebarItemPresentation? in
			guard entry.documents > 0 else {
				return nil
			}
			let itemKey = switch entry.scope.scope {
			case let .category(category):
				category.value
			case let .tag(tag):
				tag.value
			case let .sender(sender):
				sender.value
			case let .member(member):
				member.value
			case .allDocuments, .recentlyAdded, .inIngestion, .failed, .household:
				entry.scope.name
			}
			return SidebarItemPresentation(
				identifier: "\(prefix).\(itemKey)",
				title: entry.scope.name,
				symbolName: symbolName,
				accessory: .count(DocumentFormatting.groupedNumber(entry.documents)),
				kind: .destination(.library(entry.scope.scope, title: entry.scope.name))
			)
		}
		guard !items.isEmpty else {
			return nil
		}
		return SidebarSectionPresentation(identifier: identifier, title: title, items: items)
	}

	private static func foldersSection(
		collector: CollectorStatus?,
		context: ApplicationWordingContext
	) -> SidebarSectionPresentation? {
		guard let collector else {
			return nil
		}
		var items = collector.folders.map { folderStatus in
			SidebarItemPresentation(
				identifier: "folder.\(folderStatus.folder.identifier.value)",
				title: context.folderName(folderStatus.folder.root),
				symbolName: "folder",
				accessory: folderAccessory(folderStatus),
				kind: .destination(.folder(folderStatus.folder.identifier))
			)
		}
		items.append(SidebarItemPresentation(
			identifier: "folder.add",
			title: "Add Folder…",
			symbolName: "plus",
			accessory: .none,
			kind: .addFolder
		))
		return SidebarSectionPresentation(
			identifier: foldersSectionIdentifier,
			title: "Folders on This Mac",
			items: items
		)
	}

	/// A collecting folder is the usual case and shows nothing; only what differs is marked.
	private static func folderAccessory(_ folderStatus: FolderStatus) -> SidebarRowAccessory {
		switch folderStatus.unavailability {
		case .missing:
			return .attention(symbolName: "questionmark.folder", description: "Missing")
		case .accessDenied:
			return .attention(symbolName: "questionmark.folder", description: "Cannot be read")
		case nil:
			break
		}
		switch folderStatus.admission {
		case .surveying:
			return .inProgress(description: "Surveying")
		case .awaitingDecision:
			return .attention(symbolName: "exclamationmark.circle.fill", description: "Awaits your decision")
		case .collecting:
			return .none
		}
	}
}
