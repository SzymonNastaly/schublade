import { Banner, Button } from "@cloudflare/kumo"
import { PencilSimpleIcon } from "@phosphor-icons/react"
import { useQuery } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { Fragment, useState } from "react"
import { documentDetailRows } from "./document_detail_presentation"
import { DocumentRevisionForm } from "./document_revision_form"
import type { ArchiveFacets, ListedDocument } from "../archive/document_listing"
import type { VerificationReason } from "../ingestion/verification_assessment"

const verificationPrompts: Record<VerificationReason, string> = {
	new_taxonomy_record: "The classifier created a sender, category, or tag for this document.",
	illegible_required_field: "The document date or the amount could not be read. Enter it below.",
	non_archival_attachment: "The classifier read this file as boilerplate, such as general terms.",
}

const touchHeight = "max-md:inline-flex max-md:min-h-11 max-md:items-center"

function DocumentDetailList({ document, facets }: { document: ListedDocument; facets: ArchiveFacets }) {
	return (
		<dl className="grid grid-cols-[auto_minmax(0,1fr)] items-baseline gap-x-6 md:gap-y-2">
			{documentDetailRows(document, facets).map(({ label, values }) => (
				<Fragment key={label}>
					<dt className="text-kumo-subtle">{label}</dt>
					<dd className="flex flex-wrap items-baseline gap-x-3 wrap-anywhere">
						{values.map(({ text, filter }) =>
							filter === undefined ? (
								<span key={text} className={touchHeight}>
									{text}
								</span>
							) : (
								<Link key={text} to="/" search={filter} className={`underline underline-offset-2 ${touchHeight}`}>
									{text}
								</Link>
							),
						)}
					</dd>
				</Fragment>
			))}
		</dl>
	)
}

function ExtractedText({ documentId }: { documentId: string }) {
	const [expanded, setExpanded] = useState(false)
	const markdown = useQuery({
		queryKey: ["documents", documentId, "content"],
		queryFn: async () => {
			const response = await fetch(`/api/documents/${documentId}/content`)
			return response.ok ? response.text() : "No text has been extracted yet."
		},
		enabled: expanded,
	})
	return (
		<div className="flex flex-col items-start gap-2">
			<button
				type="button"
				aria-expanded={expanded}
				className={`text-sm text-kumo-subtle underline underline-offset-2 ${touchHeight}`}
				onClick={() => setExpanded(!expanded)}
			>
				{expanded ? "Hide extracted text" : "Show extracted text"}
			</button>
			{expanded && <pre className="w-full text-sm wrap-anywhere whitespace-pre-wrap">{markdown.data ?? "Loading"}</pre>}
		</div>
	)
}

/** The details of a document as plain text, or the form that revises them, with any pending verification prompt. */
export function DocumentDetails({
	document,
	facets,
	onDeleted,
}: {
	document: ListedDocument
	facets: ArchiveFacets
	onDeleted: () => void
}) {
	const [mode, setMode] = useState<"reading" | "editing">("reading")
	return (
		<section aria-label="Details" className="flex min-w-0 flex-col gap-4">
			{document.verificationReason !== null && (
				<Banner
					variant="alert"
					title="Pending verification"
					description={
						<span>
							{verificationPrompts[document.verificationReason]}{" "}
							<Link to="/verification" className={`underline ${touchHeight}`}>
								Open Pending verification
							</Link>
						</span>
					}
				/>
			)}
			{mode === "editing" ? (
				<DocumentRevisionForm
					document={document}
					facets={facets}
					onDeleted={onDeleted}
					onConcluded={() => setMode("reading")}
				/>
			) : (
				<>
					<DocumentDetailList document={document} facets={facets} />
					{document.status === "archived" && (
						<Button
							variant="secondary"
							icon={PencilSimpleIcon}
							className="w-full max-md:h-11 md:w-auto md:self-start"
							onClick={() => setMode("editing")}
						>
							Edit details
						</Button>
					)}
				</>
			)}
			<ExtractedText documentId={document.id} />
		</section>
	)
}
