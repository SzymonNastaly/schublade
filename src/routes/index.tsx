import { Button, Empty, LayerCard, Text } from "@cloudflare/kumo"
import { FilesIcon, MagnifyingGlassIcon, UploadSimpleIcon } from "@phosphor-icons/react"
import { createFileRoute, useRouter, useRouterState } from "@tanstack/react-router"
import { useEffect, useRef } from "react"
import { isSettledStatus } from "../ingestion/document_lifecycle"
import { acceptedMediaTypes } from "../ingestion/source_file"
import { ArchiveNavigation } from "../interface/archive_navigation"
import { DocumentList } from "../interface/document_list"
import { DocumentSearchControls } from "../interface/document_search_controls"
import { useDocumentStatusUpdates } from "../interface/document_status_updates"
import { useDocumentUploads } from "../interface/upload_tray"
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

function UploadControl() {
	const { start } = useDocumentUploads()
	const fileInput = useRef<HTMLInputElement>(null)
	return (
		<>
			<input
				ref={fileInput}
				type="file"
				multiple
				hidden
				accept={acceptedMediaTypes.join(",")}
				onChange={(event) => {
					// Clearing the input empties its live FileList, so the files are copied first.
					const files = [...(event.target.files ?? [])]
					event.target.value = ""
					if (files.length > 0) start(files)
				}}
			/>
			<Button variant="primary" icon={UploadSimpleIcon} onClick={() => fileInput.current?.click()}>
				Upload documents
			</Button>
		</>
	)
}

function ArchiveOverview() {
	const { documents, facets } = Route.useLoaderData()
	const criteria = Route.useSearch()
	const navigate = Route.useNavigate()
	const router = useRouter()
	const searching = useRouterState({ select: (state) => state.status === "pending" })
	const statusUpdates = useDocumentStatusUpdates(
		documents.filter((document) => !isSettledStatus(document.status)).map((document) => document.id),
	)
	useEffect(() => {
		if (statusUpdates.length > 0) void router.invalidate()
	}, [statusUpdates, router])
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
	const filtered = Object.keys(criteria).length > 0
	return (
		<main className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 md:px-6 md:py-12">
			<div className="flex flex-wrap items-center justify-between gap-4">
				<Text variant="heading1" as="h1">
					Schublade
				</Text>
				<div className="flex flex-wrap items-start gap-2">
					<ArchiveNavigation />
					<UploadControl />
				</div>
			</div>
			<DocumentSearchControls criteria={criteria} facets={facets} searching={searching} onChange={changeCriteria} />
			<LayerCard>
				<LayerCard.Secondary>
					<span className="min-w-0 wrap-break-word">
						{criteria.query === undefined
							? "Documents"
							: `${documents.length} ${documents.length === 1 ? "document matches" : "documents match"} “${criteria.query}”`}
					</span>
				</LayerCard.Secondary>
				<LayerCard.Primary>
					{documents.length === 0 ? (
						filtered ? (
							<Empty
								icon={<MagnifyingGlassIcon size={32} />}
								title="No matching documents"
								description="Search for other words or remove a filter."
							/>
						) : (
							<Empty
								icon={<FilesIcon size={32} />}
								title="No documents"
								description="Upload a PDF, JPEG, PNG, or WebP file to archive it."
							/>
						)
					) : (
						<DocumentList documents={documents} />
					)}
				</LayerCard.Primary>
			</LayerCard>
		</main>
	)
}
