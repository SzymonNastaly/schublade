import { FilesIcon, FunnelIcon, MagnifyingGlassIcon } from "@phosphor-icons/react"
import { Link, createFileRoute, useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { personOptions } from "../interface/active_filter_presentation"
import { ActiveFilterChips, ArchiveFilterPanels } from "../interface/archive_filter_panels"
import { ActionButton } from "../interface/controls/action_button"
import { EmptyState } from "../interface/controls/empty_state"
import { FilterTab, FilterTabs } from "../interface/controls/filter_tabs"
import { BreadcrumbTrail, ListFrame, PageColumns, PageContent, PageHeading } from "../interface/controls/page_layout"
import { textLinkClasses } from "../interface/controls/text_link"
import { DocumentList } from "../interface/document_list"
import { useArchiveChanges } from "../interface/document_status_updates"
import { parseSearchParameters } from "../search/search_criteria"
import { listArchiveFacets, retrieveDocuments } from "../utilities/server_functions"
import type { SearchCriteria } from "../search/search_criteria"

export const Route = createFileRoute("/")({
	validateSearch: parseSearchParameters,
	// The router merges a review's entry parameter into this search, and the server function refuses it.
	loaderDeps: ({ search }) => parseSearchParameters(search),
	loader: async ({ deps }) => {
		const [documents, facets] = await Promise.all([retrieveDocuments({ data: deps }), listArchiveFacets()])
		return { documents, facets }
	},
	component: ArchiveOverview,
})

function documentCountLabel(count: number): string {
	return count === 1 ? "1 document" : `${count} documents`
}

function ArchiveOverview() {
	const { documents, facets } = Route.useLoaderData()
	const criteria = Route.useSearch()
	const navigate = Route.useNavigate()
	const router = useRouter()
	const [filtersShown, setFiltersShown] = useState(false)
	useArchiveChanges(() => {
		// A new document takes minutes to reach the index, so a text search would repeat a billed
		// query for nothing. The latest location also covers a search that is still loading.
		if (router.latestLocation.search.query === undefined) void router.invalidate()
	})
	const changeCriteria = (changes: Partial<SearchCriteria>) =>
		void navigate({
			search: (previous) =>
				Object.fromEntries(
					Object.entries<string | number | undefined>({ ...previous, ...changes }).filter(
						([, value]) => value !== undefined,
					),
				),
			replace: true,
		})
	const selectionName =
		facets.categories.find((category) => category.id === criteria.category)?.name ??
		facets.senders.find((sender) => sender.id === criteria.sender)?.name
	const filtered = Object.keys(criteria).length > 0
	const filterControls = { criteria, facets, onChange: changeCriteria }
	return (
		<PageContent>
			<BreadcrumbTrail current={selectionName ?? "All documents"}>
				{selectionName !== undefined && (
					<Link to="/" className={textLinkClasses}>
						All documents
					</Link>
				)}
			</BreadcrumbTrail>
			<PageColumns panels={<ArchiveFilterPanels {...filterControls} />}>
				<div className="flex items-start justify-between gap-3">
					<PageHeading
						title={criteria.query === undefined ? (selectionName ?? "All documents") : "Search results"}
						subtitle={
							criteria.query === undefined
								? `${documentCountLabel(documents.length)} in your household archive, newest first.`
								: `${documentCountLabel(documents.length)} ${documents.length === 1 ? "matches" : "match"} “${criteria.query}”.`
						}
					/>
					<div className="lg:hidden">
						<ActionButton
							variant="secondary"
							icon={FunnelIcon}
							aria-expanded={filtersShown}
							onClick={() => setFiltersShown(!filtersShown)}
						>
							Filters
						</ActionButton>
					</div>
				</div>
				{filtersShown && (
					<div className="flex flex-col gap-3.5 md:grid md:grid-cols-2 md:items-start lg:hidden">
						<ArchiveFilterPanels {...filterControls} />
					</div>
				)}
				<ActiveFilterChips {...filterControls} />
				<div>
					{facets.members.length > 1 && (
						<FilterTabs label="Show documents for">
							<FilterTab
								selected={criteria.person === undefined}
								onSelect={() => changeCriteria({ person: undefined })}
							>
								Everyone
							</FilterTab>
							{personOptions(facets).map((person) => (
								<FilterTab
									key={person.id}
									selected={criteria.person === person.id}
									onSelect={() => changeCriteria({ person: person.id })}
								>
									{person.name}
								</FilterTab>
							))}
						</FilterTabs>
					)}
					<ListFrame>
						{documents.length === 0 ? (
							filtered ? (
								<EmptyState
									icon={<MagnifyingGlassIcon size={32} />}
									title="No matching documents"
									description="Search for other words or remove a filter."
								/>
							) : (
								<EmptyState
									icon={<FilesIcon size={32} />}
									title="No documents"
									description="Upload a PDF, JPEG, PNG, or WebP file to archive it."
								/>
							)
						) : (
							<DocumentList documents={documents} />
						)}
					</ListFrame>
				</div>
			</PageColumns>
		</PageContent>
	)
}
