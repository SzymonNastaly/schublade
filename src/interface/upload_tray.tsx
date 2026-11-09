import { Button, Text } from "@cloudflare/kumo"
import { ArrowClockwiseIcon, TrashIcon, XIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { Link, useRouter } from "@tanstack/react-router"
import { createContext, useContext, useEffect, useReducer } from "react"
import { isSettledStatus } from "../ingestion/document_lifecycle"
import { submitDocumentDeletion, submitDocumentIngestionRetry } from "../utilities/server_functions"
import { ActionConfirmation, documentDeletionDescription } from "./action_confirmation"
import { StatusBadge } from "./controls/status_badge"
import { documentFailureSentences, documentStatusBadges } from "./document_status_presentation"
import { useDocumentStatusUpdates } from "./document_status_updates"
import { isFinishedUpload, reduceTrackedUploads, unfinishedDocumentIds } from "./tracked_uploads"
import type { UploadOutcome } from "../ingestion/document_upload"
import type { TrackedUpload, TrackedUploadEvent } from "./tracked_uploads"
import type { ActionDispatch, ReactNode } from "react"

interface DocumentUploads {
	uploads: ReadonlyArray<TrackedUpload>
	start: (files: Array<File>) => void
	retry: (documentId: string) => Promise<void>
	dispatch: ActionDispatch<[event: TrackedUploadEvent]>
}

const DocumentUploadsContext = createContext<DocumentUploads | null>(null)

export function useDocumentUploads(): DocumentUploads {
	const documentUploads = useContext(DocumentUploadsContext)
	if (documentUploads === null) throw new Error("useDocumentUploads needs a DocumentUploadsProvider above it")
	return documentUploads
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

/** Holds the uploads above the routes, so they continue while a member moves between pages. */
export function DocumentUploadsProvider({ children }: { children: ReactNode }) {
	const router = useRouter()
	const [uploads, dispatch] = useReducer(reduceTrackedUploads, [])
	const statusRecords = useDocumentStatusUpdates(unfinishedDocumentIds(uploads))
	useEffect(() => {
		if (statusRecords.length === 0) return
		dispatch({ kind: "statuses_received", records: statusRecords })
		if (statusRecords.some((record) => isSettledStatus(record.status))) void router.invalidate()
	}, [statusRecords, router])

	const start = (files: Array<File>) => {
		const submitted = files.map((file) => ({ key: crypto.randomUUID(), fileName: file.name }))
		dispatch({ kind: "submitted", uploads: submitted })
		void uploadDocuments(files)
			.catch((error: Error) =>
				files.map((file): UploadOutcome => ({ kind: "failed", fileName: file.name, reason: error.message })),
			)
			.then((outcomes) => {
				dispatch({ kind: "answered", keys: submitted.map((upload) => upload.key), outcomes })
				void router.invalidate()
			})
	}
	const retry = async (documentId: string) => {
		await submitDocumentIngestionRetry({ data: { documentId } })
		dispatch({ kind: "retried", documentId })
		await router.invalidate()
	}
	return (
		<DocumentUploadsContext.Provider value={{ uploads, start, retry, dispatch }}>
			{children}
		</DocumentUploadsContext.Provider>
	)
}

const sideBySideAction = "min-w-0 flex-1 max-md:h-11 md:flex-none"

/** Retry and Delete for a failed document, in the tray and in the Pending verification review. */
export function FailedDocumentActions({ documentId, title }: { documentId: string; title: string | null }) {
	const router = useRouter()
	const { retry, dispatch } = useDocumentUploads()
	const retrial = useMutation({ mutationFn: () => retry(documentId) })
	return (
		<div className="flex flex-col gap-2 pt-1">
			{retrial.isError && <Text variant="error">{retrial.error.message}</Text>}
			<div className="flex gap-2">
				<Button
					variant="primary"
					icon={ArrowClockwiseIcon}
					className={sideBySideAction}
					loading={retrial.isPending}
					onClick={() => retrial.mutate()}
				>
					Retry
				</Button>
				<ActionConfirmation
					label="Delete"
					icon={TrashIcon}
					variant="secondary-destructive"
					className={sideBySideAction}
					title="Delete this document?"
					description={documentDeletionDescription(title)}
					confirmationLabel="Delete"
					confirmationVariant="destructive"
					action={() => submitDocumentDeletion({ data: { documentId } })}
					onCompleted={() => {
						dispatch({ kind: "document_deleted", documentId })
						return router.invalidate()
					}}
				/>
			</div>
		</div>
	)
}

const openLink =
	"text-sm text-kumo-link underline underline-offset-2 max-md:inline-flex max-md:min-h-11 max-md:items-center"

function RowFrame({ name, trailing, children }: { name: string; trailing: ReactNode; children?: ReactNode }) {
	return (
		<li className="flex flex-col gap-1 px-4 py-2">
			<div className="flex items-center justify-between gap-2">
				<span className="min-w-0 text-sm font-medium wrap-anywhere">{name}</span>
				<span className="shrink-0">{trailing}</span>
			</div>
			{children}
		</li>
	)
}

function TrackedDocumentRow({ upload }: { upload: Extract<TrackedUpload, { stage: "tracked" }> }) {
	const name = upload.title ?? upload.fileName
	const badge = documentStatusBadges[upload.status]
	switch (upload.status) {
		case "archived":
			return (
				<RowFrame
					name={name}
					trailing={
						<Link to="/documents/$documentId" params={{ documentId: upload.documentId }} className={openLink}>
							Open
						</Link>
					}
				>
					{upload.needsReview && (
						<Text variant="secondary" size="sm">
							Archived, needs review
						</Text>
					)}
				</RowFrame>
			)
		case "failed":
			return (
				<RowFrame name={name} trailing={<StatusBadge tone={badge.tone}>{badge.label}</StatusBadge>}>
					<Text variant="secondary" size="sm">
						{documentFailureSentences[upload.failureReason ?? "processing_error"]}
					</Text>
					<FailedDocumentActions documentId={upload.documentId} title={name} />
				</RowFrame>
			)
		default:
			return <RowFrame name={name} trailing={<StatusBadge tone={badge.tone}>{badge.label}</StatusBadge>} />
	}
}

function UploadRow({ upload }: { upload: TrackedUpload }) {
	const { dispatch } = useDocumentUploads()
	switch (upload.stage) {
		case "uploading":
			return <RowFrame name={upload.fileName} trailing={<StatusBadge tone="neutral">Uploading</StatusBadge>} />
		case "refused":
			return (
				<RowFrame
					name={upload.fileName}
					trailing={
						<Button
							variant="ghost"
							shape="square"
							size="sm"
							icon={XIcon}
							aria-label={`Dismiss ${upload.fileName}`}
							className="max-md:size-11"
							onClick={() => dispatch({ kind: "dismissed", key: upload.key })}
						/>
					}
				>
					<Text variant="error" size="sm">
						{upload.reason}
					</Text>
				</RowFrame>
			)
		case "tracked":
			return <TrackedDocumentRow upload={upload} />
	}
}

/** It sets no z-index, so the confirmation dialog, which renders later in the document, covers it. */
export function UploadTray() {
	const { uploads, dispatch } = useDocumentUploads()
	if (uploads.length === 0) return null
	return (
		<>
			{/* Keeps the end of a page reachable above the tray on a phone. */}
			<div aria-hidden className="h-[50vh] md:hidden" />
			<section
				aria-label="Uploads"
				className="fixed inset-x-0 bottom-[calc(3.5rem+env(safe-area-inset-bottom))] flex max-h-[50vh] flex-col border-t border-kumo-hairline bg-kumo-elevated shadow-lg md:inset-x-auto md:right-4 md:bottom-4 md:max-h-[60vh] md:w-[360px] md:rounded-lg md:border"
			>
				<header className="flex items-center justify-between gap-2 border-b border-kumo-hairline py-1 pr-2 pl-4">
					<h2 className="font-medium">Uploads</h2>
					<Button
						variant="ghost"
						size="sm"
						className="max-md:h-11"
						disabled={!uploads.some(isFinishedUpload)}
						onClick={() => dispatch({ kind: "finished_cleared" })}
					>
						Clear finished
					</Button>
				</header>
				<ul className="flex min-h-0 flex-col divide-y divide-kumo-hairline overflow-y-auto">
					{uploads.map((upload) => (
						<UploadRow key={upload.key} upload={upload} />
					))}
				</ul>
			</section>
		</>
	)
}
