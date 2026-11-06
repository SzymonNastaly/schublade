import { Badge, Table, Text } from "@cloudflare/kumo"
import type { BadgeVariant } from "@cloudflare/kumo"
import type { DocumentStatus } from "../ingestion/document_lifecycle"
import type { RetrievedDocument } from "../search/document_search"

const statusBadges: Record<DocumentStatus, { label: string; variant: BadgeVariant }> = {
	processing: { label: "Processing", variant: "secondary" },
	extracting: { label: "Extracting", variant: "info" },
	recognizing_text: { label: "Recognizing text", variant: "info" },
	classifying: { label: "Classifying", variant: "info" },
	archived: { label: "Archived", variant: "success" },
	failed: { label: "Failed", variant: "error" },
}

function primaryAmount(document: RetrievedDocument): string {
	const amount = document.fields.find((field) => field.fieldKey === "amount")?.value
	const currency = document.fields.find((field) => field.fieldKey === "currency")?.value
	if (typeof amount !== "number") return ""
	return `${amount.toFixed(2)} ${typeof currency === "string" ? currency : ""}`.trim()
}

function personLabel(document: RetrievedDocument): string {
	if (document.personName !== null) return document.personName
	return document.status === "archived" ? "Household" : ""
}

function StatusBadge({ status }: { status: DocumentStatus }) {
	return <Badge variant={statusBadges[status].variant}>{statusBadges[status].label}</Badge>
}

interface DocumentListProperties {
	documents: Array<RetrievedDocument>
	selectedDocumentId: string | undefined
	onSelect: (documentId: string) => void
}

/** A stacked row per document below the md breakpoint, and a table from md upward. */
export function DocumentList({ documents, selectedDocumentId, onSelect }: DocumentListProperties) {
	return (
		<>
			<ul className="-mx-2 flex flex-col md:hidden">
				{documents.map((document) => (
					<li key={document.id}>
						<button
							type="button"
							aria-current={document.id === selectedDocumentId}
							onClick={() => onSelect(document.id)}
							className="flex w-full min-w-0 flex-col gap-1 rounded-lg px-2 py-3 text-left aria-[current=true]:bg-kumo-tint"
						>
							<span className="flex items-start justify-between gap-2">
								<span className="min-w-0 font-medium break-words">{document.title ?? "Untitled document"}</span>
								{document.status !== "archived" && <StatusBadge status={document.status} />}
							</span>
							<span className="flex flex-wrap gap-x-3 gap-y-0.5 text-sm text-kumo-subtle">
								{[document.senderName, document.documentDate, personLabel(document), primaryAmount(document)]
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
						</button>
					</li>
				))}
			</ul>
			<div className="hidden md:block">
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
								onClick={() => onSelect(document.id)}
							>
								<Table.Cell className="whitespace-nowrap tabular-nums">{document.documentDate}</Table.Cell>
								<Table.Cell>{document.senderName}</Table.Cell>
								<Table.Cell>
									<span className="flex flex-col gap-1">
										<span>{document.title}</span>
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
								<Table.Cell>
									<StatusBadge status={document.status} />
								</Table.Cell>
							</Table.Row>
						))}
					</Table.Body>
				</Table>
			</div>
		</>
	)
}
