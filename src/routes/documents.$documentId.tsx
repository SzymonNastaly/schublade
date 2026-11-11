import { FileXIcon } from "@phosphor-icons/react"
import { Link, createFileRoute, notFound, useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { EmptyState } from "../interface/controls/empty_state"
import {
	BreadcrumbTrail,
	PageColumns,
	PageContent,
	PageHeading,
	PhoneReturnBar,
} from "../interface/controls/page_layout"
import { textLinkClasses } from "../interface/controls/text_link"
import { DocumentDetails, DocumentSources } from "../interface/document_details"
import { DocumentPanels } from "../interface/document_panels"
import { listArchiveFacets, retrieveDocument, retrieveDocuments } from "../utilities/server_functions"

export const Route = createFileRoute("/documents/$documentId")({
	loader: async ({ params }) => {
		const [document, facets] = await Promise.all([
			retrieveDocument({ data: { documentId: params.documentId } }),
			listArchiveFacets(),
		])
		if (document === null) throw notFound()
		const sender = facets.senders.find((option) => option.name === document.senderName)
		const senderDocuments = sender === undefined ? [] : await retrieveDocuments({ data: { sender: sender.id } })
		return { document, facets, sender, senderDocuments }
	},
	component: DocumentPage,
	notFoundComponent: () => (
		<PageContent>
			<BreadcrumbTrail current="Document not found">
				<Link to="/" className={textLinkClasses}>
					Documents
				</Link>
			</BreadcrumbTrail>
			<EmptyState
				icon={<FileXIcon size={32} />}
				title="This document does not exist"
				description="Someone may have deleted it."
			/>
		</PageContent>
	),
})

function DocumentPage() {
	const { document } = Route.useLoaderData()
	// Keyed so that moving to another document leaves its form closed and its first tab open.
	return <DocumentWorkspace key={document.id} />
}

function DocumentWorkspace() {
	const { document, facets, sender, senderDocuments } = Route.useLoaderData()
	const router = useRouter()
	const navigate = Route.useNavigate()
	const [editing, setEditing] = useState(false)
	const title = document.title ?? "Untitled document"
	const category = facets.categories.find((option) => option.name === document.categoryName)
	return (
		<>
			<PhoneReturnBar to="/">Documents</PhoneReturnBar>
			<PageContent>
				<BreadcrumbTrail current={title}>
					<Link to="/" className={textLinkClasses}>
						Documents
					</Link>
					{category !== undefined && (
						<Link to="/" search={{ category: category.id }} className={textLinkClasses}>
							{category.name}
						</Link>
					)}
				</BreadcrumbTrail>
				<PageColumns
					panelsFollowContent
					panels={
						<DocumentPanels
							document={document}
							sender={sender}
							senderDocuments={senderDocuments}
							onEdit={() => setEditing(true)}
							onDeleted={() => {
								if (router.history.canGoBack()) router.history.back()
								else void navigate({ to: "/" })
							}}
						/>
					}
				>
					<PageHeading title={title} subtitle={document.summary} />
					<div className="flex flex-wrap items-start gap-6">
						<DocumentSources document={document} />
						<DocumentDetails
							document={document}
							facets={facets}
							editing={editing}
							onEditingConcluded={() => setEditing(false)}
						/>
					</div>
				</PageColumns>
			</PageContent>
		</>
	)
}
