import { SealCheckIcon } from "@phosphor-icons/react"
import { Link, createFileRoute } from "@tanstack/react-router"
import { useState } from "react"
import { actionClasses } from "../interface/controls/action_button"
import { EmptyState } from "../interface/controls/empty_state"
import {
	BreadcrumbTrail,
	ListFrame,
	PageColumns,
	PageContent,
	PageHeading,
	PhoneReturnBar,
} from "../interface/controls/page_layout"
import { SectionPanel, panelRowClasses } from "../interface/controls/section_panel"
import { StatusBadge } from "../interface/controls/status_badge"
import { textLinkClasses } from "../interface/controls/text_link"
import { DocumentOriginal } from "../interface/document_original"
import {
	describeVerificationQuestion,
	locateReviewStep,
	reviewedDocument,
	summarizeVerificationEntry,
	verificationEntryKey,
} from "../interface/verification_entries"
import { VerificationEntryControls } from "../interface/verification_entry_controls"
import { listArchiveFacets, retrieveVerificationItems } from "../utilities/server_functions"
import type { ArchiveFacets } from "../archive/document_listing"
import type { VerificationItem } from "../archive/verification_items"

export const Route = createFileRoute("/verification_/review")({
	validateSearch: (search: Record<string, unknown>): { entry?: string } =>
		typeof search.entry === "string" ? { entry: search.entry } : {},
	loader: async () => {
		const [items, facets] = await Promise.all([retrieveVerificationItems(), listArchiveFacets()])
		return { items, facets }
	},
	component: VerificationReviewPage,
})

function skippedEntriesNote(skippedCount: number): string {
	if (skippedCount === 0) return "Every entry is resolved."
	return skippedCount === 1
		? "The entry you skipped stays pending."
		: `The ${skippedCount} entries you skipped stay pending.`
}

function ReviewedEntry({ item, facets }: { item: VerificationItem; facets: ArchiveFacets }) {
	const document = reviewedDocument(item)
	const controls = <VerificationEntryControls item={item} facets={facets} />
	if (document === undefined) return <div className="max-w-[420px]">{controls}</div>
	return (
		<div className="flex flex-wrap items-start gap-6">
			<div className="min-w-0 flex-[3_1_480px] max-md:max-h-72 max-md:overflow-hidden">
				<ListFrame>
					<DocumentOriginal document={document} />
				</ListFrame>
			</div>
			<div className="flex min-w-0 flex-[2_1_320px] flex-col gap-3">
				{controls}
				<Link
					to="/documents/$documentId"
					params={{ documentId: document.id }}
					className={`flex min-h-11 items-center justify-center font-bold md:min-h-0 md:justify-start ${textLinkClasses}`}
				>
					Open this document ›
				</Link>
			</div>
		</div>
	)
}

function UpNextPanel({ items, currentKey }: { items: Array<VerificationItem>; currentKey: string }) {
	return (
		<SectionPanel section="verification" heading="Up next">
			{items.map((item) => {
				const key = verificationEntryKey(item)
				const { badge, subject } = summarizeVerificationEntry(item)
				return (
					<Link
						key={key}
						to="/verification/review"
						search={{ entry: key }}
						aria-current={key === currentKey ? "step" : undefined}
						className={panelRowClasses({ section: "verification", selected: key === currentKey })}
					>
						<span className="flex min-w-0 flex-col gap-0.5">
							<span className="wrap-anywhere">{subject}</span>
							<span className="text-fine font-normal text-caption">{badge.label}</span>
						</span>
					</Link>
				)
			})}
		</SectionPanel>
	)
}

function VerificationReviewPage() {
	const { items, facets } = Route.useLoaderData()
	const { entry: requestedKey } = Route.useSearch()
	const [entryOrder] = useState(() => items.map(verificationEntryKey))
	const [skippedKeys, setSkippedKeys] = useState<ReadonlySet<string>>(new Set())
	const step = locateReviewStep({ items, entryOrder, skippedKeys, requestedKey })
	const breadcrumb = (
		<BreadcrumbTrail current="Review">
			<Link to="/verification" className={textLinkClasses}>
				Pending verification
			</Link>
		</BreadcrumbTrail>
	)
	if (step.kind === "finished") {
		return (
			<>
				<PhoneReturnBar to="/verification">Pending verification</PhoneReturnBar>
				<PageContent>
					{breadcrumb}
					<EmptyState
						icon={<SealCheckIcon size={64} weight="fill" />}
						title="Nothing left to review"
						description={skippedEntriesNote(step.skippedCount)}
					>
						<Link to="/verification" className={`flex min-h-11 items-center font-bold ${textLinkClasses}`}>
							Back to Pending verification
						</Link>
					</EmptyState>
				</PageContent>
			</>
		)
	}
	const key = verificationEntryKey(step.item)
	const { question, explanation } = describeVerificationQuestion(step.item)
	const progress = <StatusBadge tone="verification">{`${step.ordinal} of ${step.total}`}</StatusBadge>
	const skip = (
		<Link
			to="/verification/review"
			search={{ entry: step.successorKey }}
			className={actionClasses({ variant: "plain", size: "compact" })}
			onClick={() => setSkippedKeys(new Set(skippedKeys).add(key))}
		>
			Skip ›
		</Link>
	)
	return (
		<>
			<PhoneReturnBar
				to="/verification"
				trailing={
					<>
						{progress}
						{skip}
					</>
				}
			>
				Pending verification
			</PhoneReturnBar>
			<PageContent>
				{breadcrumb}
				<PageColumns panels={<UpNextPanel items={items} currentKey={key} />}>
					<div className="flex items-start justify-between gap-6">
						<PageHeading title={question} subtitle={explanation} />
						<div className="flex flex-none items-center gap-2 pt-2 max-md:hidden">
							{progress}
							{skip}
						</div>
					</div>
					{/* Keyed so an entry's half-filled form and drawn document never carry over to the next one. */}
					<ReviewedEntry key={key} item={step.item} facets={facets} />
				</PageColumns>
			</PageContent>
		</>
	)
}
