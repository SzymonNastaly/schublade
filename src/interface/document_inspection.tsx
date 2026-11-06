import { LayerCard, Tabs, Text } from "@cloudflare/kumo"
import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { DocumentRevisionForm } from "./document_revision_form"
import type { ArchiveFacets, ListedDocument } from "../archive/document_listing"

export function DocumentInspection({
	document,
	facets,
	onDeleted,
}: {
	document: ListedDocument
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
