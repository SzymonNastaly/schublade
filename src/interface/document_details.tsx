import { Tabs } from "@base-ui/react/tabs"
import { CheckCircleIcon } from "@phosphor-icons/react"
import { useQuery } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { Fragment } from "react"
import { frameTabClasses, frameTabRowClasses } from "./controls/filter_tabs"
import { ListFrame, SectionHeading } from "./controls/page_layout"
import { StatusBadge } from "./controls/status_badge"
import { textLinkClasses } from "./controls/text_link"
import { documentDetailRows } from "./document_detail_presentation"
import { DocumentOriginal } from "./document_original"
import { DocumentRevisionForm } from "./document_revision_form"
import { documentStatusBadges } from "./document_status_presentation"
import { documentBoxFrame } from "./pdf_page_box"
import type { ArchiveFacets, ListedDocument } from "../archive/document_listing"

const labelCell = "border-b border-table-rule bg-table-label px-3 py-2.5 text-field-label"
const valueCell =
	"m-0 flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-table-rule px-3 py-2.5 font-bold wrap-anywhere"

function DocumentStatusValue({ document }: { document: ListedDocument }) {
	if (document.status !== "archived") {
		const badge = documentStatusBadges[document.status]
		return <StatusBadge tone={badge.tone}>{badge.label}</StatusBadge>
	}
	return (
		<>
			<CheckCircleIcon size={18} weight="fill" className="text-primary" />
			Archived
		</>
	)
}

function DocumentDetailTable({ document, facets }: { document: ListedDocument; facets: ArchiveFacets }) {
	return (
		<dl className="grid grid-cols-[112px_minmax(0,1fr)] overflow-hidden rounded-table border border-table-border [&>*:nth-last-child(-n+2)]:border-b-0">
			<dt className={labelCell}>Status</dt>
			<dd className={valueCell}>
				<DocumentStatusValue document={document} />
			</dd>
			{documentDetailRows(document, facets).map(({ label, values }) => (
				<Fragment key={label}>
					<dt className={labelCell}>{label}</dt>
					<dd className={valueCell}>
						{values.map(({ text, filter }) =>
							filter === undefined ? (
								<span key={text}>{text}</span>
							) : (
								<Link key={text} to="/" search={filter} className={textLinkClasses}>
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
	const markdown = useQuery({
		queryKey: ["documents", documentId, "content"],
		queryFn: async () => {
			const response = await fetch(`/api/documents/${documentId}/content`)
			return response.ok ? response.text() : "No text has been extracted yet."
		},
	})
	return (
		<pre
			className={`${documentBoxFrame} overflow-auto bg-surface p-5 font-body leading-relaxed wrap-anywhere whitespace-pre-wrap`}
		>
			{markdown.data ?? "Loading"}
		</pre>
	)
}

/** The original file and the extracted text, one at a time. */
export function DocumentSources({ document }: { document: ListedDocument }) {
	return (
		<Tabs.Root defaultValue="original" className="min-w-0 flex-[3_1_480px]">
			<Tabs.List className={frameTabRowClasses}>
				<Tabs.Tab value="original" className={frameTabClasses}>
					Original
				</Tabs.Tab>
				<Tabs.Tab value="text" className={frameTabClasses}>
					Extracted text
				</Tabs.Tab>
			</Tabs.List>
			<ListFrame>
				<Tabs.Panel value="original" keepMounted className="data-[hidden]:hidden">
					<DocumentOriginal document={document} />
				</Tabs.Panel>
				<Tabs.Panel value="text">
					<ExtractedText documentId={document.id} />
				</Tabs.Panel>
			</ListFrame>
		</Tabs.Root>
	)
}

interface DocumentDetailsProperties {
	document: ListedDocument
	facets: ArchiveFacets
	editing: boolean
	onEditingConcluded: () => void
}

/** The details of a document as a table, or the form that revises them. */
export function DocumentDetails({ document, facets, editing, onEditingConcluded }: DocumentDetailsProperties) {
	return (
		<section aria-label="Details" className="flex min-w-0 flex-[2_1_320px] flex-col gap-3">
			<SectionHeading>Details</SectionHeading>
			{editing ? (
				<DocumentRevisionForm document={document} facets={facets} onConcluded={onEditingConcluded} />
			) : (
				<DocumentDetailTable document={document} facets={facets} />
			)}
		</section>
	)
}
