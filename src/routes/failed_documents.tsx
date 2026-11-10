import { SealCheckIcon } from "@phosphor-icons/react"
import { Link, createFileRoute } from "@tanstack/react-router"
import { EmptyState } from "../interface/controls/empty_state"
import { BreadcrumbTrail, ListFrame, PageContent, PageHeading } from "../interface/controls/page_layout"
import { textLinkClasses } from "../interface/controls/text_link"
import { DocumentThumbnail } from "../interface/document_thumbnail"
import { documentFailureSentences } from "../interface/document_status_presentation"
import { FailedDocumentActions } from "../interface/upload_tray"
import { retrieveFailedDocuments } from "../utilities/server_functions"
import type { FailedDocument } from "../archive/failed_documents"

export const Route = createFileRoute("/failed_documents")({
	loader: () => retrieveFailedDocuments(),
	component: FailedDocumentsPage,
})

function FailedDocumentRow({ document }: { document: FailedDocument }) {
	return (
		<li className="flex items-start gap-3 border-b border-dotted border-row-rule px-3.5 py-2.5 last:border-b-0">
			<DocumentThumbnail documentId={document.id} className="h-[46px] w-[34px]" />
			<div className="flex min-w-0 flex-1 flex-col items-start gap-0.5">
				<Link
					to="/documents/$documentId"
					params={{ documentId: document.id }}
					className={`text-[13.5px] font-bold wrap-anywhere ${textLinkClasses}`}
				>
					{document.title ?? "Untitled document"}
				</Link>
				<p className="text-fine text-caption">{documentFailureSentences[document.failureReason]}</p>
				<FailedDocumentActions documentId={document.id} title={document.title} />
			</div>
		</li>
	)
}

function FailedDocumentsPage() {
	const failedDocuments = Route.useLoaderData()
	return (
		<PageContent>
			<BreadcrumbTrail current="Failed documents" />
			<PageHeading
				title="Failed documents"
				subtitle={
					failedDocuments.length === 0
						? null
						: `${failedDocuments.length === 1 ? "1 document" : `${failedDocuments.length} documents`} could not be archived. Retry or delete each one.`
				}
			/>
			<ListFrame>
				{failedDocuments.length === 0 ? (
					<EmptyState
						icon={<SealCheckIcon size={56} weight="fill" />}
						title="No failed documents"
						description="A document that Schublade cannot archive appears here."
					/>
				) : (
					<ul className="flex flex-col">
						{failedDocuments.map((document) => (
							<FailedDocumentRow key={document.id} document={document} />
						))}
					</ul>
				)}
			</ListFrame>
		</PageContent>
	)
}
