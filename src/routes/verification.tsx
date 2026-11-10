import { SealCheckIcon } from "@phosphor-icons/react"
import { Link, createFileRoute } from "@tanstack/react-router"
import { actionClasses } from "../interface/controls/action_button"
import { EmptyState } from "../interface/controls/empty_state"
import { BreadcrumbTrail, ListFrame, PageContent, PageHeading } from "../interface/controls/page_layout"
import { StatusBadge } from "../interface/controls/status_badge"
import { DocumentThumbnail } from "../interface/document_thumbnail"
import { summarizeVerificationEntry, verificationEntryKey } from "../interface/verification_entries"
import { retrieveVerificationItems } from "../utilities/server_functions"
import type { VerificationItem } from "../archive/verification_items"

export const Route = createFileRoute("/verification")({
	loader: () => retrieveVerificationItems(),
	component: PendingVerificationPage,
})

function EntryRow({ item }: { item: VerificationItem }) {
	const { badge, subject, note } = summarizeVerificationEntry(item)
	return (
		<li>
			<Link
				to="/verification/review"
				search={{ entry: verificationEntryKey(item) }}
				className="flex min-h-[60px] items-stretch gap-3 border-b border-dotted border-row-rule py-2.5 pr-3.5 pl-2 hover:bg-row-hover"
			>
				<span
					className={`w-[5px] flex-none rounded-[3px] ${badge.tone === "failure" ? "bg-failure" : "bg-verification"}`}
				/>
				<DocumentThumbnail documentId={item.document.id} className="h-[46px] w-[34px] self-center" />
				<span className="flex min-w-0 flex-1 flex-col items-start justify-center gap-0.5">
					<span className="flex flex-wrap items-center gap-2">
						<span className="text-[13.5px] font-bold wrap-anywhere text-link">{subject}</span>
						<StatusBadge tone={badge.tone}>{badge.label}</StatusBadge>
					</span>
					<span className="text-fine text-caption">{note}</span>
				</span>
				<span className="self-center font-bold whitespace-nowrap text-link max-md:hidden">Review ›</span>
			</Link>
		</li>
	)
}

function itemCountLabel(count: number): string {
	return count === 1 ? "1 item" : `${count} items`
}

function PendingVerificationPage() {
	const items = Route.useLoaderData()
	return (
		<PageContent>
			<BreadcrumbTrail current="Pending verification" />
			<PageHeading
				title="Pending verification"
				subtitle={
					items.length === 0
						? "You are all caught up."
						: `${itemCountLabel(items.length)} ${items.length === 1 ? "needs" : "need"} a quick look from you.`
				}
			/>
			{items.length === 0 ? (
				<ListFrame>
					<EmptyState
						icon={<SealCheckIcon size={56} weight="fill" />}
						title="Nothing awaits verification"
						description="Every document is archived and searchable. Failed documents appear here."
					/>
				</ListFrame>
			) : (
				<>
					<div className="flex flex-col gap-2 md:flex-row">
						<Link to="/verification/review" className={actionClasses({ variant: "primary", stretchOnPhone: true })}>
							Review {itemCountLabel(items.length)}
						</Link>
					</div>
					<ListFrame>
						<ul className="flex flex-col">
							{items.map((item) => (
								<EntryRow key={verificationEntryKey(item)} item={item} />
							))}
						</ul>
					</ListFrame>
				</>
			)}
		</PageContent>
	)
}
