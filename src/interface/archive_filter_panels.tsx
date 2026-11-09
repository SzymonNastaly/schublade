import { XIcon } from "@phosphor-icons/react"
import { Link, useLoaderData } from "@tanstack/react-router"
import { useState } from "react"
import { activeFilters, visibleFacetOptions } from "./active_filter_presentation"
import { useCommittedText } from "./committed_text"
import { ActionButton, actionClasses } from "./controls/action_button"
import { TextField } from "./controls/form_fields"
import { PanelRowButton, SectionPanel } from "./controls/section_panel"
import type { ArchiveFacets, FacetOption } from "../archive/document_listing"
import type { SearchCriteria } from "../search/search_criteria"

type CriteriaChange = (changes: Partial<SearchCriteria>) => void

function AmountField({
	label,
	amount,
	onCommit,
}: {
	label: string
	amount: number | undefined
	onCommit: (amount: number | undefined) => void
}) {
	const [text, setText] = useCommittedText(amount === undefined ? "" : String(amount), (committed) => {
		const parsed = Number(committed)
		if (committed === "") onCommit(undefined)
		else if (Number.isFinite(parsed) && parsed >= 0) onCommit(parsed)
	})
	return (
		<TextField
			label={label}
			type="number"
			inputMode="decimal"
			min={0}
			step={0.01}
			value={text}
			onChange={(event) => setText(event.target.value)}
		/>
	)
}

interface FacetPanelProperties {
	heading: string
	/** The plural noun that names the options, such as "senders". */
	noun: string
	options: Array<FacetOption>
	selected: string | undefined
	onSelect: (id: string | undefined) => void
}

function FacetPanel({ heading, noun, options, selected, onSelect }: FacetPanelProperties) {
	const [expanded, setExpanded] = useState(false)
	const [searchText, setSearchText] = useState("")
	if (options.length === 0) return null
	const { visible, collapsible } = visibleFacetOptions(options, { expanded, searchText, selected })
	return (
		<SectionPanel section="documents" heading={heading}>
			{expanded && (
				<div className="border-b border-documents-rule p-2">
					<TextField
						label={<span className="sr-only">Find {noun}</span>}
						placeholder={`Find ${noun}`}
						value={searchText}
						onChange={(event) => setSearchText(event.target.value)}
					/>
				</div>
			)}
			<div className={expanded ? "max-h-80 overflow-y-auto" : ""}>
				{visible.map((option) => (
					<PanelRowButton
						key={option.id}
						section="documents"
						selected={option.id === selected}
						onClick={() => onSelect(option.id === selected ? undefined : option.id)}
					>
						<span className="min-w-0 flex-1 truncate">{option.name}</span>
						<span className="text-fine font-normal text-caption">{option.documentCount}</span>
					</PanelRowButton>
				))}
			</div>
			{collapsible && (
				<ActionButton variant="plain" size="compact" onClick={() => setExpanded(!expanded)}>
					{expanded ? `Show fewer ${noun}` : `All ${options.length} ${noun} ›`}
				</ActionButton>
			)}
		</SectionPanel>
	)
}

function PendingVerificationPanel() {
	const pendingVerificationCount = useLoaderData({ from: "__root__" })
	if (pendingVerificationCount === 0) return null
	return (
		<SectionPanel section="verification" heading="Pending verification" tinted>
			<div className="flex flex-col items-start gap-2.5 p-3">
				<p>
					{pendingVerificationCount === 1 ? "1 item needs" : `${pendingVerificationCount} items need`} a quick look from
					you.
				</p>
				<Link to="/verification" className={actionClasses({ variant: "secondary", size: "compact" })}>
					Review now ›
				</Link>
			</div>
		</SectionPanel>
	)
}

interface ArchiveFilterPanelsProperties {
	criteria: SearchCriteria
	facets: ArchiveFacets
	onChange: CriteriaChange
}

export function ArchiveFilterPanels({ criteria, facets, onChange }: ArchiveFilterPanelsProperties) {
	return (
		<>
			<PendingVerificationPanel />
			<FacetPanel
				heading="Categories"
				noun="categories"
				options={facets.categories}
				selected={criteria.category}
				onSelect={(category) => onChange({ category })}
			/>
			<FacetPanel
				heading="Senders"
				noun="senders"
				options={facets.senders}
				selected={criteria.sender}
				onSelect={(sender) => onChange({ sender })}
			/>
			<FacetPanel
				heading="Tags"
				noun="tags"
				options={facets.tags}
				selected={criteria.tag}
				onSelect={(tag) => onChange({ tag })}
			/>
			<SectionPanel section="documents" heading="Date and amount">
				<div className="flex flex-col gap-2.5 p-3">
					<TextField
						label="From"
						type="date"
						value={criteria.earliestDocumentDate ?? ""}
						onChange={(event) => onChange({ earliestDocumentDate: event.target.value || undefined })}
					/>
					<TextField
						label="Until"
						type="date"
						value={criteria.latestDocumentDate ?? ""}
						onChange={(event) => onChange({ latestDocumentDate: event.target.value || undefined })}
					/>
					<div className="grid grid-cols-2 gap-2.5">
						<AmountField
							label="Minimum"
							amount={criteria.minimumAmount}
							onCommit={(minimumAmount) => onChange({ minimumAmount })}
						/>
						<AmountField
							label="Maximum"
							amount={criteria.maximumAmount}
							onCommit={(maximumAmount) => onChange({ maximumAmount })}
						/>
					</div>
				</div>
			</SectionPanel>
		</>
	)
}

/** The active filters, each removable. The person shows on its tab instead. */
export function ActiveFilterChips({ criteria, facets, onChange }: ArchiveFilterPanelsProperties) {
	const filters = activeFilters(criteria, facets).filter(({ criterion }) => criterion !== "person")
	if (filters.length === 0) return null
	return (
		<div className="flex flex-wrap items-center gap-2 text-fine text-caption">
			<span>Showing only</span>
			{filters.map(({ criterion, label }) => (
				<button
					key={criterion}
					type="button"
					aria-label={`Remove filter ${label}`}
					onClick={() => onChange({ [criterion]: undefined })}
					className="inline-flex h-11 max-w-full cursor-pointer items-center gap-2 rounded-[15px] border border-chip-border bg-chip px-3 text-on-accent md:h-[30px]"
				>
					<span className="truncate">{label}</span>
					<XIcon size={11} weight="bold" className="flex-none" />
				</button>
			))}
			<ActionButton
				variant="plain"
				size="compact"
				onClick={() => onChange(Object.fromEntries(filters.map(({ criterion }) => [criterion, undefined])))}
			>
				Clear all
			</ActionButton>
		</div>
	)
}
