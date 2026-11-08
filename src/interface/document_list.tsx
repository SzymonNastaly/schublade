import { Badge, Table, Text } from "@cloudflare/kumo"
import { Link } from "@tanstack/react-router"
import { formatAmount, formatDocumentDate } from "./document_formatting"
import { documentStatusBadges } from "./document_status_presentation"
import { DocumentThumbnail } from "./document_thumbnail"
import type { DocumentStatus } from "../ingestion/document_lifecycle"
import type { RetrievedDocument } from "../search/document_search"

function primaryAmount(document: RetrievedDocument): string {
	const amount = document.fields.find((field) => field.fieldKey === "amount")?.value
	const currency = document.fields.find((field) => field.fieldKey === "currency")?.value
	if (typeof amount !== "number") return ""
	return formatAmount(amount, typeof currency === "string" ? currency : undefined)
}

function personLabel(document: RetrievedDocument): string {
	if (document.personName !== null) return document.personName
	return document.status === "archived" ? "Household" : ""
}

function dateLabel(document: RetrievedDocument): string {
	return document.documentDate === null ? "" : formatDocumentDate(document.documentDate)
}

function UnfinishedStatus({ status }: { status: DocumentStatus }) {
	if (status === "archived") return null
	return <Badge variant={documentStatusBadges[status].variant}>{documentStatusBadges[status].label}</Badge>
}

/** A stacked row per document below the md breakpoint, and a table from md upward. Every row opens its document. */
export function DocumentList({ documents }: { documents: Array<RetrievedDocument> }) {
	return (
		<>
			<ul className="-mx-2 flex flex-col md:hidden">
				{documents.map((document) => (
					<li key={document.id}>
						<Link
							to="/documents/$documentId"
							params={{ documentId: document.id }}
							className="flex w-full min-w-0 items-start gap-3 rounded-lg px-2 py-3 text-left active:bg-kumo-tint"
						>
							<DocumentThumbnail documentId={document.id} className="h-[58px] w-[42px]" />
							<span className="flex min-w-0 flex-1 flex-col gap-1">
								<span className="flex items-start justify-between gap-2">
									<span className="min-w-0 font-medium break-words">{document.title ?? "Untitled document"}</span>
									<UnfinishedStatus status={document.status} />
								</span>
								<span className="flex flex-wrap gap-x-3 gap-y-0.5 text-sm text-kumo-subtle">
									{[document.senderName, dateLabel(document), personLabel(document), primaryAmount(document)]
										.filter((detail) => detail !== null && detail !== "")
										.map((detail, index) => (
											<span key={index} className="min-w-0 break-words tabular-nums">
												{detail}
											</span>
										))}
								</span>
								{document.matchingPassage !== null && (
									<Text variant="secondary" size="sm" as="span">
										<span className="line-clamp-3 break-words">{document.matchingPassage}</span>
									</Text>
								)}
							</span>
						</Link>
					</li>
				))}
			</ul>
			<div className="hidden md:block">
				<Table>
					<Table.Header>
						<Table.Row>
							<Table.Head>
								<span className="sr-only">Preview</span>
							</Table.Head>
							<Table.Head>Date</Table.Head>
							<Table.Head>Sender</Table.Head>
							<Table.Head>Title</Table.Head>
							<Table.Head>Person</Table.Head>
							<Table.Head>Category</Table.Head>
							<Table.Head>Amount</Table.Head>
						</Table.Row>
					</Table.Header>
					<Table.Body>
						{documents.map((document) => (
							<Table.Row key={document.id} className="relative cursor-pointer hover:bg-kumo-tint">
								<Table.Cell>
									<DocumentThumbnail documentId={document.id} className="block h-[38px] w-[28px]" />
								</Table.Cell>
								<Table.Cell className="whitespace-nowrap tabular-nums">{dateLabel(document)}</Table.Cell>
								<Table.Cell>{document.senderName}</Table.Cell>
								<Table.Cell>
									<span className="flex flex-col gap-1">
										<span className="flex items-center gap-2">
											<Link
												to="/documents/$documentId"
												params={{ documentId: document.id }}
												className="after:absolute after:inset-0"
											>
												{document.title ?? "Untitled document"}
											</Link>
											<UnfinishedStatus status={document.status} />
										</span>
										{document.matchingPassage !== null && (
											<Text variant="secondary" size="sm" as="span">
												<span className="line-clamp-2">{document.matchingPassage}</span>
											</Text>
										)}
									</span>
								</Table.Cell>
								<Table.Cell>{personLabel(document)}</Table.Cell>
								<Table.Cell>{document.categoryName}</Table.Cell>
								<Table.Cell className="text-right whitespace-nowrap tabular-nums">{primaryAmount(document)}</Table.Cell>
							</Table.Row>
						))}
					</Table.Body>
				</Table>
			</div>
		</>
	)
}
