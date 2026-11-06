import { Button, Empty, LayerCard, Tabs, Text } from "@cloudflare/kumo"
import { FilesIcon, MagnifyingGlassIcon, UploadSimpleIcon } from "@phosphor-icons/react"
import { useMutation, useQuery } from "@tanstack/react-query"
import { createFileRoute, useRouter, useRouterState } from "@tanstack/react-router"
import { useEffect, useRef, useState } from "react"
import { isSettledStatus } from "../ingestion/document_lifecycle"
import { acceptedMediaTypes } from "../ingestion/source_file"
import { ArchiveNavigation } from "../interface/archive_navigation"
import { DocumentList } from "../interface/document_list"
import { DocumentRevisionForm } from "../interface/document_revision_form"
import { DocumentSearchControls } from "../interface/document_search_controls"
import { parseSearchParameters } from "../search/search_criteria"
import { listArchiveFacets, retrieveDocuments } from "../utilities/server_functions"
import type { ArchiveFacets } from "../archive/document_listing"
import type { UploadOutcome } from "../ingestion/document_upload"
import type { SearchCriteria } from "../search/search_criteria"
import type { RetrievedDocument } from "../search/document_search"

export const Route = createFileRoute("/")({
	validateSearch: parseSearchParameters,
	loaderDeps: ({ search }) => search,
	loader: async ({ deps }) => {
		const [documents, facets] = await Promise.all([retrieveDocuments({ data: deps }), listArchiveFacets()])
		return { documents, facets }
	},
	component: ArchiveOverview,
})

const DOCUMENT_LISTING_REFRESH_MILLISECONDS = 2000

async function uploadDocuments(files: Array<File>): Promise<Array<UploadOutcome>> {
	const formData = new FormData()
	for (const file of files) formData.append("files", file)
	const response = await fetch("/api/documents", { method: "POST", body: formData })
	if (!response.ok) {
		const failure = await response.json<{ error?: string }>().catch(() => ({ error: undefined }))
		throw new Error(failure.error ?? `The upload failed with status ${response.status}`)
	}
	const { outcomes } = await response.json<{ outcomes: Array<UploadOutcome> }>()
	return outcomes
}

function UploadControl() {
	const router = useRouter()
	const fileInput = useRef<HTMLInputElement>(null)
	const upload = useMutation({
		mutationFn: uploadDocuments,
		onSettled: () => router.invalidate(),
	})
	const unarchivedOutcomes = upload.data?.filter((outcome) => outcome.kind !== "accepted") ?? []
	return (
		<div className="flex flex-col items-end gap-2">
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
					if (files.length > 0) upload.mutate(files)
				}}
			/>
			<Button
				variant="primary"
				icon={UploadSimpleIcon}
				loading={upload.isPending}
				onClick={() => fileInput.current?.click()}
			>
				Upload documents
			</Button>
			{upload.isError && <Text variant="error">{upload.error.message}</Text>}
			{unarchivedOutcomes.map((outcome, index) => (
				<Text key={index} variant="error">
					{outcome.fileName}: {outcome.reason}
				</Text>
			))}
		</div>
	)
}

function DocumentInspection({
	document,
	facets,
	onDeleted,
}: {
	document: RetrievedDocument
	facets: ArchiveFacets
	onDeleted: () => void
}) {
	const [representation, setRepresentation] = useState("original")
	const markdown = useQuery({
		queryKey: ["documents", document.id, "content"],
		queryFn: async () => {
			const response = await fetch(`/api/documents/${document.id}/content`)
			return response.ok ? response.text() : "No text has been extracted yet."
		},
		enabled: representation === "content",
	})
	const originalUrl = `/api/documents/${document.id}/original`
	return (
		<LayerCard>
			<LayerCard.Secondary>{document.title ?? "Untitled document"}</LayerCard.Secondary>
			<LayerCard.Primary className="flex flex-col gap-4">
				{document.summary !== null && <Text>{document.summary}</Text>}
				<DocumentRevisionForm document={document} facets={facets} onDeleted={onDeleted} />
				<Tabs
					tabs={[
						{ value: "original", label: "Original" },
						{ value: "content", label: "Text" },
					]}
					value={representation}
					onValueChange={setRepresentation}
				/>
				{document.status === "awaiting_rendering" ? (
					<Text variant="secondary">
						This email has no PDF or image attachment. Schublade stores the message and will archive it once it can
						render the email as a PDF.
					</Text>
				) : representation === "original" ? (
					document.mimeType === "application/pdf" ? (
						<iframe title="Original document" src={originalUrl} className="h-[80vh] w-full rounded border" />
					) : (
						<img alt="Original document" src={originalUrl} className="max-h-[80vh] w-full object-contain" />
					)
				) : (
					<pre className="max-h-[80vh] overflow-auto text-sm whitespace-pre-wrap">{markdown.data ?? "Loading"}</pre>
				)}
			</LayerCard.Primary>
		</LayerCard>
	)
}

function ArchiveOverview() {
	const { documents, facets } = Route.useLoaderData()
	const criteria = Route.useSearch()
	const navigate = Route.useNavigate()
	const router = useRouter()
	const searching = useRouterState({ select: (state) => state.status === "pending" })
	const [selectedDocumentId, setSelectedDocumentId] = useState<string>()
	const hasUnsettledDocument = documents.some((document) => !isSettledStatus(document.status))
	useEffect(() => {
		if (!hasUnsettledDocument) return
		const timer = setInterval(() => void router.invalidate(), DOCUMENT_LISTING_REFRESH_MILLISECONDS)
		return () => clearInterval(timer)
	}, [hasUnsettledDocument, router])
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
	const selectedDocument = documents.find((document) => document.id === selectedDocumentId)
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
						<DocumentList
							documents={documents}
							selectedDocumentId={selectedDocumentId}
							onSelect={setSelectedDocumentId}
						/>
					)}
				</LayerCard.Primary>
			</LayerCard>
			{selectedDocument && (
				<DocumentInspection
					key={selectedDocument.id}
					document={selectedDocument}
					facets={facets}
					onDeleted={() => setSelectedDocumentId(undefined)}
				/>
			)}
		</main>
	)
}
