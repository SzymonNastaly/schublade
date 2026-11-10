import { Link, useRouter } from "@tanstack/react-router"
import { submitDocumentDeletion } from "../utilities/server_functions"
import { MAIL_MEDIA_TYPE } from "../ingestion/source_file"
import { ActionConfirmation, documentDeletionDescription } from "./action_confirmation"
import { actionClasses } from "./controls/action_button"
import { PanelRowButton, SectionPanel, panelRowClasses } from "./controls/section_panel"
import type { ListedDocument } from "../archive/document_listing"
import type { RetrievedDocument } from "../search/document_search"

const verificationPrompts: Record<NonNullable<ListedDocument["verificationReason"]>, string> = {
	non_archival_attachment: "The classifier read this file as boilerplate, such as general terms.",
}

const MAXIMUM_RELATED_DOCUMENTS = 3

/** The prompt to verify a document, compact above the document on a phone. */
export function PhoneVerificationNotice({ document }: { document: ListedDocument }) {
	if (document.verificationReason === null) return null
	return (
		<div className="flex items-center justify-between gap-2.5 rounded-tr-panel rounded-b-field border border-verification-border bg-verification-surface px-3 py-2 text-verification-badge-text lg:hidden">
			<span>
				<strong>Pending verification.</strong> {verificationPrompts[document.verificationReason]}
			</span>
			<Link
				to="/verification/review"
				search={{ entry: document.id }}
				className="flex min-h-11 items-center font-bold whitespace-nowrap"
			>
				Review ›
			</Link>
		</div>
	)
}

interface DocumentPanelsProperties {
	document: ListedDocument
	sender: { id: string; name: string } | undefined
	senderDocuments: Array<RetrievedDocument>
	onEdit: () => void
	onDeleted: () => void
}

export function DocumentPanels({ document, sender, senderDocuments, onEdit, onDeleted }: DocumentPanelsProperties) {
	const router = useRouter()
	const archived = document.status === "archived"
	const relatedDocuments = senderDocuments.filter((other) => other.id !== document.id)
	return (
		<>
			{document.verificationReason !== null && (
				<div className="max-lg:hidden">
					<SectionPanel section="verification" heading="Pending verification" tinted>
						<div className="flex flex-col items-start gap-2.5 p-3">
							<p>{verificationPrompts[document.verificationReason]}</p>
							<Link
								to="/verification/review"
								search={{ entry: document.id }}
								className={actionClasses({ variant: "secondary", size: "compact" })}
							>
								Review now ›
							</Link>
						</div>
					</SectionPanel>
				</div>
			)}
			<SectionPanel section="documents" heading="Actions">
				{archived && (
					<PanelRowButton section="documents" onClick={onEdit}>
						<span aria-hidden>›</span>Edit details
					</PanelRowButton>
				)}
				{document.mimeType !== MAIL_MEDIA_TYPE && (
					<a
						href={`/api/documents/${document.id}/original`}
						target="_blank"
						rel="noopener"
						className={panelRowClasses({ section: "documents" })}
					>
						<span aria-hidden>›</span>Open original
					</a>
				)}
				{archived && (
					<ActionConfirmation
						trigger={(open) => (
							<PanelRowButton section="documents" destructive onClick={open}>
								<span aria-hidden>›</span>Delete document
							</PanelRowButton>
						)}
						title="Delete this document?"
						description={documentDeletionDescription(document.title)}
						confirmationLabel="Delete"
						confirmationVariant="destructive"
						action={() => submitDocumentDeletion({ data: { documentId: document.id } })}
						onCompleted={() => {
							onDeleted()
							return router.invalidate()
						}}
					/>
				)}
			</SectionPanel>
			{sender !== undefined && relatedDocuments.length > 0 && (
				<SectionPanel section="documents" heading="More from this sender">
					{relatedDocuments.slice(0, MAXIMUM_RELATED_DOCUMENTS).map((related) => (
						<Link
							key={related.id}
							to="/documents/$documentId"
							params={{ documentId: related.id }}
							className={panelRowClasses({ section: "documents" })}
						>
							<span className="min-w-0 wrap-anywhere">{related.title ?? "Untitled document"}</span>
						</Link>
					))}
					<Link
						to="/"
						search={{ sender: sender.id }}
						className="flex min-h-11 items-center px-3 text-fine font-bold text-link md:min-h-9"
					>
						All {senderDocuments.length} documents ›
					</Link>
				</SectionPanel>
			)}
		</>
	)
}
