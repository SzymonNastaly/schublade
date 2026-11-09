import { Link } from "@tanstack/react-router"
import { StatusBadge } from "./controls/status_badge"
import { formatAmount, formatDocumentDate } from "./document_formatting"
import { documentStatusBadges } from "./document_status_presentation"
import { DocumentThumbnail } from "./document_thumbnail"
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

/** Orange asks for the member's attention, blue is still at work, and red has failed. */
function rowEdgeColour(document: RetrievedDocument): string {
	if (document.status === "failed") return "bg-failure"
	if (document.status !== "archived") return "bg-documents"
	return document.verificationReason === null ? "bg-row-edge" : "bg-verification"
}

function DocumentStateBadge({ document }: { document: RetrievedDocument }) {
	if (document.status !== "archived") {
		const badge = documentStatusBadges[document.status]
		return <StatusBadge tone={badge.tone}>{badge.label}</StatusBadge>
	}
	if (document.verificationReason === null) return null
	return <StatusBadge tone="verification">Pending verification</StatusBadge>
}

function MatchingPassage({ document }: { document: RetrievedDocument }) {
	if (document.matchingPassage === null) return null
	return <span className="line-clamp-2 text-fine break-words text-caption">{document.matchingPassage}</span>
}

/** A stacked row per document below the md breakpoint, and a table from md upward. Every row opens its document. */
export function DocumentList({ documents }: { documents: Array<RetrievedDocument> }) {
	return (
		<>
			<ul className="flex flex-col @xl:hidden">
				{documents.map((document) => (
					<li key={document.id}>
						<Link
							to="/documents/$documentId"
							params={{ documentId: document.id }}
							className="flex items-stretch gap-2.5 border-b border-dotted border-row-rule py-2.5 pr-3 pl-1.5"
						>
							<span className={`w-[5px] flex-none rounded-[3px] ${rowEdgeColour(document)}`} />
							<DocumentThumbnail documentId={document.id} className="h-12 w-9 self-start" />
							<span className="flex min-w-0 flex-1 flex-col gap-0.5">
								<span className="text-sm font-bold break-words text-link">{document.title ?? "Untitled document"}</span>
								<span className="text-fine break-words text-caption">{document.senderName}</span>
								<span className="flex justify-between gap-2 text-fine text-caption">
									<span>{[dateLabel(document), personLabel(document)].filter(Boolean).join(" · ")}</span>
									<span className="font-bold whitespace-nowrap text-foreground">{primaryAmount(document)}</span>
								</span>
								<span>
									<DocumentStateBadge document={document} />
								</span>
								<MatchingPassage document={document} />
							</span>
						</Link>
					</li>
				))}
			</ul>
			<table className="hidden w-full table-fixed border-collapse @xl:table">
				<thead>
					<tr className="border-b border-table-rule text-left text-fine text-caption">
						<th className="w-[13px]" />
						<th className="w-[52px]">
							<span className="sr-only">Preview</span>
						</th>
						<th className="py-2 pr-3 font-bold">Document</th>
						<th className="hidden w-[132px] py-2 pr-3 font-bold @2xl:table-cell">Category</th>
						<th className="hidden w-[142px] py-2 pr-3 font-bold @4xl:table-cell">Person</th>
						<th className="w-[108px] py-2 pr-3 font-bold">Date</th>
						<th className="w-[104px] py-2 pr-3.5 text-right font-bold">Amount</th>
					</tr>
				</thead>
				<tbody>
					{documents.map((document) => (
						<tr
							key={document.id}
							className="relative cursor-pointer border-b border-dotted border-row-rule hover:bg-row-hover"
						>
							<td className="py-2 pl-2">
								<span className={`block h-11 w-[5px] rounded-[3px] ${rowEdgeColour(document)}`} />
							</td>
							<td className="py-2 pl-1.5">
								<DocumentThumbnail documentId={document.id} className="block h-[46px] w-[34px]" />
							</td>
							<td className="py-2 pr-3">
								<span className="flex min-w-0 flex-col gap-0.5">
									<Link
										to="/documents/$documentId"
										params={{ documentId: document.id }}
										className="text-[13.5px] font-bold break-words text-link after:absolute after:inset-0"
									>
										{document.title ?? "Untitled document"}
									</Link>
									<span className="flex flex-wrap items-center gap-2 text-fine text-caption">
										{document.senderName !== null && <span>from {document.senderName}</span>}
										<span className="@4xl:hidden">{personLabel(document)}</span>
										<span className="@2xl:hidden">{document.categoryName}</span>
										<DocumentStateBadge document={document} />
									</span>
									<MatchingPassage document={document} />
								</span>
							</td>
							<td className="hidden py-2 pr-3 break-words @2xl:table-cell">{document.categoryName}</td>
							<td className="hidden py-2 pr-3 break-words @4xl:table-cell">{personLabel(document)}</td>
							<td className="py-2 pr-3 whitespace-nowrap tabular-nums">{dateLabel(document)}</td>
							<td className="py-2 pr-3.5 text-right whitespace-nowrap tabular-nums">{primaryAmount(document)}</td>
						</tr>
					))}
				</tbody>
			</table>
		</>
	)
}
