import { CheckCircleIcon, SealCheckIcon } from "@phosphor-icons/react"
import { Link, createFileRoute } from "@tanstack/react-router"
import { useState } from "react"
import { actionClasses } from "../interface/controls/action_button"
import { EmptyState } from "../interface/controls/empty_state"
import { FilterTab, FilterTabs } from "../interface/controls/filter_tabs"
import { BreadcrumbTrail, ListFrame, PageColumns, PageContent, PageHeading } from "../interface/controls/page_layout"
import { PanelRowButton, SectionPanel } from "../interface/controls/section_panel"
import { StatusBadge } from "../interface/controls/status_badge"
import { DocumentThumbnail } from "../interface/document_thumbnail"
import { NewSenderConfirmation } from "../interface/new_sender_confirmation"
import {
	reviewedDocument,
	selectNewSenders,
	summarizeVerificationEntry,
	verificationEntryKey,
	verificationFilterOptions,
} from "../interface/verification_entries"
import { retrieveVerificationItems } from "../utilities/server_functions"
import type { VerificationFilter } from "../interface/verification_entries"
import type { VerificationItem } from "../archive/verification_items"

export const Route = createFileRoute("/verification")({
	loader: () => retrieveVerificationItems(),
	component: PendingVerificationPage,
})

function EntryRow({ item }: { item: VerificationItem }) {
	const { badge, subject, note } = summarizeVerificationEntry(item)
	const document = reviewedDocument(item)
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
				{document === undefined ? (
					<span className="w-[34px] flex-none" />
				) : (
					<DocumentThumbnail documentId={document.id} className="h-[46px] w-[34px] self-center" />
				)}
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
	const [filter, setFilter] = useState<VerificationFilter>("all")
	const [confirmedSenderCount, setConfirmedSenderCount] = useState<number | null>(null)
	const newSenders = selectNewSenders(items)
	const filterOptions = verificationFilterOptions(items).filter((option) => option.count > 0)
	const activeFilter = filterOptions.some((option) => option.filter === filter) ? filter : "all"
	const shownItems = items.filter((item) => activeFilter === "all" || item.reason === activeFilter)
	return (
		<PageContent>
			<BreadcrumbTrail current="Pending verification" />
			<PageColumns
				panels={
					<SectionPanel section="verification" heading="Waiting for you">
						{filterOptions.map((option) => (
							<PanelRowButton
								key={option.filter}
								section="verification"
								selected={option.filter === activeFilter}
								onClick={() => setFilter(option.filter)}
							>
								<span className="flex-1">{option.label}</span>
								<span className="text-fine font-normal text-caption">{option.count}</span>
							</PanelRowButton>
						))}
					</SectionPanel>
				}
			>
				<PageHeading
					title="Pending verification"
					subtitle={
						items.length === 0
							? "You are all caught up."
							: `${itemCountLabel(items.length)} ${items.length === 1 ? "needs" : "need"} a quick look from you.`
					}
				/>
				{confirmedSenderCount !== null && (
					<p role="status" className="flex items-center gap-2 text-field-label">
						<CheckCircleIcon size={18} weight="fill" className="text-primary" />
						{confirmedSenderCount === 1 ? "1 sender" : `${confirmedSenderCount} senders`} confirmed
					</p>
				)}
				{items.length === 0 ? (
					<ListFrame>
						<EmptyState
							icon={<SealCheckIcon size={56} weight="fill" />}
							title="Nothing awaits verification"
							description="Every document is archived and searchable. New senders, unreadable fields, attachments, and failed documents appear here."
						/>
					</ListFrame>
				) : (
					<>
						<div className="flex flex-col gap-2 md:flex-row">
							<Link to="/verification/review" className={actionClasses({ variant: "primary", stretchOnPhone: true })}>
								Review {itemCountLabel(items.length)}
							</Link>
							{newSenders.senders.length > 0 && (
								<NewSenderConfirmation {...newSenders} onConfirmed={setConfirmedSenderCount} />
							)}
						</div>
						<div>
							<div className="md:hidden">
								<FilterTabs label="Show entries for">
									{filterOptions.map((option) => (
										<FilterTab
											key={option.filter}
											selected={option.filter === activeFilter}
											onSelect={() => setFilter(option.filter)}
										>
											{option.label} {option.count}
										</FilterTab>
									))}
								</FilterTabs>
							</div>
							<ListFrame>
								<ul className="flex flex-col">
									{shownItems.map((item) => (
										<EntryRow key={verificationEntryKey(item)} item={item} />
									))}
								</ul>
							</ListFrame>
						</div>
					</>
				)}
			</PageColumns>
		</PageContent>
	)
}
