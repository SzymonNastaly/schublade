import { Badge, Button, Empty, LayerCard, Table, Tabs, Text } from "@cloudflare/kumo"
import { FilesIcon, UploadSimpleIcon } from "@phosphor-icons/react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { createFileRoute } from "@tanstack/react-router"
import { useRef, useState } from "react"
import { isSettledStatus } from "../ingestion/document_lifecycle"
import { acceptedMediaTypes } from "../ingestion/source_file"
import { listDocuments } from "../utilities/server_functions"
import type { BadgeVariant } from "@cloudflare/kumo"
import type { ListedDocument } from "../archive/document_listing"
import type { DocumentStatus } from "../ingestion/document_lifecycle"
import type { UploadOutcome } from "../ingestion/document_upload"

export const Route = createFileRoute("/")({
	loader: () => listDocuments(),
	component: ArchiveOverview,
})

const DOCUMENT_LISTING_REFRESH_MILLISECONDS = 2000

const statusBadges: Record<DocumentStatus, { label: string; variant: BadgeVariant }> = {
	processing: { label: "Processing", variant: "secondary" },
	extracting: { label: "Extracting", variant: "info" },
	recognizing_text: { label: "Recognizing text", variant: "info" },
	classifying: { label: "Classifying", variant: "info" },
	archived: { label: "Archived", variant: "success" },
	failed: { label: "Failed", variant: "error" },
}

function primaryAmount(document: ListedDocument): string {
	const amount = document.fields.find((field) => field.fieldKey === "amount")?.value
	const currency = document.fields.find((field) => field.fieldKey === "currency")?.value
	if (typeof amount !== "number") return ""
	return `${amount.toFixed(2)} ${typeof currency === "string" ? currency : ""}`.trim()
}

function personLabel(document: ListedDocument): string {
	if (document.personName !== null) return document.personName
	return document.status === "archived" ? "Household" : ""
}

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
	const queryClient = useQueryClient()
	const fileInput = useRef<HTMLInputElement>(null)
	const upload = useMutation({
		mutationFn: uploadDocuments,
		onSettled: () => queryClient.invalidateQueries({ queryKey: ["documents"] }),
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

function DocumentInspection({ document }: { document: ListedDocument }) {
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
				<Tabs
					tabs={[
						{ value: "original", label: "Original" },
						{ value: "content", label: "Text" },
					]}
					value={representation}
					onValueChange={setRepresentation}
				/>
				{representation === "original" ? (
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
	const initialDocuments = Route.useLoaderData()
	const [selectedDocumentId, setSelectedDocumentId] = useState<string>()
	const { data: documents } = useQuery({
		queryKey: ["documents"],
		queryFn: () => listDocuments(),
		initialData: initialDocuments,
		refetchInterval: (query) =>
			query.state.data?.some((document) => !isSettledStatus(document.status))
				? DOCUMENT_LISTING_REFRESH_MILLISECONDS
				: false,
	})
	const selectedDocument = documents.find((document) => document.id === selectedDocumentId)
	return (
		<main className="mx-auto flex max-w-6xl flex-col gap-6 px-6 py-12">
			<div className="flex items-center justify-between gap-4">
				<Text variant="heading1" as="h1">
					Schublade
				</Text>
				<UploadControl />
			</div>
			<LayerCard>
				<LayerCard.Secondary>Documents</LayerCard.Secondary>
				<LayerCard.Primary>
					{documents.length === 0 ? (
						<Empty
							icon={<FilesIcon size={32} />}
							title="No documents"
							description="Upload a PDF, JPEG, PNG, or WebP file to archive it."
						/>
					) : (
						<Table>
							<Table.Header>
								<Table.Row>
									<Table.Head>Date</Table.Head>
									<Table.Head>Sender</Table.Head>
									<Table.Head>Title</Table.Head>
									<Table.Head>Person</Table.Head>
									<Table.Head>Category</Table.Head>
									<Table.Head>Amount</Table.Head>
									<Table.Head>Status</Table.Head>
								</Table.Row>
							</Table.Header>
							<Table.Body>
								{documents.map((document) => (
									<Table.Row
										key={document.id}
										variant={document.id === selectedDocumentId ? "selected" : "default"}
										className="cursor-pointer"
										onClick={() => setSelectedDocumentId(document.id)}
									>
										<Table.Cell>{document.documentDate}</Table.Cell>
										<Table.Cell>{document.senderName}</Table.Cell>
										<Table.Cell>{document.title}</Table.Cell>
										<Table.Cell>{personLabel(document)}</Table.Cell>
										<Table.Cell>{document.categoryName}</Table.Cell>
										<Table.Cell className="text-right tabular-nums">{primaryAmount(document)}</Table.Cell>
										<Table.Cell>
											<Badge variant={statusBadges[document.status].variant}>
												{statusBadges[document.status].label}
											</Badge>
										</Table.Cell>
									</Table.Row>
								))}
							</Table.Body>
						</Table>
					)}
				</LayerCard.Primary>
			</LayerCard>
			{selectedDocument && <DocumentInspection key={selectedDocument.id} document={selectedDocument} />}
		</main>
	)
}
