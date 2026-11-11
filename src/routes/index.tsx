import { FilesIcon, MagnifyingGlassIcon } from "@phosphor-icons/react"
import { createFileRoute, useRouter } from "@tanstack/react-router"
import { ArchiveFilterBar } from "../interface/archive_filter_bar"
import { EmptyState } from "../interface/controls/empty_state"
import { ListFrame, PageContent } from "../interface/controls/page_layout"
import { DocumentList } from "../interface/document_list"
import { useArchiveChanges } from "../interface/document_status_updates"
import { parseSearchParameters } from "../search/search_criteria"
import { listArchiveFacets, retrieveDocuments } from "../utilities/server_functions"
import type { SearchCriteria } from "../search/search_criteria"

export const Route = createFileRoute("/")({
	validateSearch: parseSearchParameters,
	loaderDeps: ({ search }) => search,
	loader: async ({ deps }) => {
		const [documents, facets] = await Promise.all([retrieveDocuments({ data: deps }), listArchiveFacets()])
		return { documents, facets }
	},
	component: ArchiveOverview,
})

function ArchiveOverview() {
	const { documents, facets } = Route.useLoaderData()
	const criteria = Route.useSearch()
	const navigate = Route.useNavigate()
	const router = useRouter()
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
	return (
		<>
			<ArchiveFilterBar
				criteria={criteria}
				facets={facets}
				documentCount={documents.length}
				onChange={changeCriteria}
			/>
			<PageContent>
				<ListFrame>
					{documents.length === 0 ? (
						Object.keys(criteria).length > 0 ? (
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
			</PageContent>
		</>
	)
}
