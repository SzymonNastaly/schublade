import { PencilSimpleIcon } from "@phosphor-icons/react"
import { useState } from "react"
import {
	activeFilterValue,
	archiveFilters,
	clearedCriteria,
	filteredTaxonomyRecord,
	offersOptionSearch,
	presentedFilters,
	rankedOptions,
} from "./active_filter_presentation"
import { useCommittedText } from "./committed_text"
import { ActionButton } from "./controls/action_button"
import { FilterPopover } from "./controls/filter_popover"
import { TextField } from "./controls/form_fields"
import { PanelRowButton } from "./controls/section_panel"
import { TaxonomyRecordDialog } from "./taxonomy_record_dialog"
import type { ArchiveFilter } from "./active_filter_presentation"
import type { ArchiveFacets } from "../archive/document_listing"
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

interface OptionListProperties {
	filter: Extract<ArchiveFilter, { kind: "option" }>
	criteria: SearchCriteria
	facets: ArchiveFacets
	onChange: CriteriaChange
	onMaintainRecord: (recordId: string) => void
	close: () => void
}

function OptionList({ filter, criteria, facets, onChange, onMaintainRecord, close }: OptionListProperties) {
	const [searchText, setSearchText] = useState("")
	const options = filter.options(facets)
	const selected = criteria[filter.criterion]
	const record = filteredTaxonomyRecord(filter, criteria, facets)
	const listed = rankedOptions(options, searchText)
	return (
		<>
			{offersOptionSearch(options) && (
				<div className="border-b border-documents-rule p-2">
					<TextField
						label={<span className="sr-only">Find {filter.noun}</span>}
						placeholder={`Find ${filter.noun}`}
						value={searchText}
						onChange={(event) => setSearchText(event.target.value)}
					/>
				</div>
			)}
			<div className="min-h-0 overflow-y-auto">
				{listed.length === 0 && <p className="px-3 py-2 text-caption">No {filter.noun} found.</p>}
				{listed.map((option) => (
					<PanelRowButton
						key={option.id}
						section="documents"
						selected={option.id === selected}
						onClick={() => {
							onChange({ [filter.criterion]: option.id === selected ? undefined : option.id })
							close()
						}}
					>
						<span className="min-w-0 flex-1 truncate">{option.name}</span>
						<span className="text-fine font-normal text-caption">{option.documentCount}</span>
					</PanelRowButton>
				))}
			</div>
			{record !== undefined && (
				<div className="border-t border-documents-border">
					<PanelRowButton
						section="documents"
						onClick={() => {
							close()
							onMaintainRecord(record.id)
						}}
					>
						<PencilSimpleIcon size={16} />
						Rename, merge, or delete…
					</PanelRowButton>
				</div>
			)}
		</>
	)
}

interface ArchiveFilterBarProperties {
	criteria: SearchCriteria
	facets: ArchiveFacets
	documentCount: number
	onChange: CriteriaChange
}

/** The filters of the archive, one control each, as the lower part of the search toolbar. */
export function ArchiveFilterBar({ criteria, facets, documentCount, onChange }: ArchiveFilterBarProperties) {
	const [maintenance, setMaintenance] = useState<{ filter: ArchiveFilter; recordId: string } | null>(null)
	const filters = presentedFilters(criteria, facets)
	const filtered = filters.some((filter) => activeFilterValue(filter, criteria, facets) !== undefined)
	// A merge moves the filter to another record and a deletion removes it, and either closes the dialog.
	const maintainedRecord = maintenance && filteredTaxonomyRecord(maintenance.filter, criteria, facets)
	return (
		<div className="flex [scrollbar-width:none] items-center gap-2 overflow-x-auto border-b border-toolbar-border bg-filter-bar px-3 pb-2 md:flex-wrap md:overflow-visible md:pr-5 md:pb-2.5 md:pl-[55px]">
			{filters.map((filter) => (
				<FilterPopover
					key={filter.label}
					label={filter.label}
					value={activeFilterValue(filter, criteria, facets)}
					onClear={() => onChange(clearedCriteria([filter]))}
				>
					{(close) => {
						switch (filter.kind) {
							case "option":
								return (
									<OptionList
										filter={filter}
										criteria={criteria}
										facets={facets}
										onChange={onChange}
										onMaintainRecord={(recordId) => setMaintenance({ filter, recordId })}
										close={close}
									/>
								)
							case "date_range":
								return (
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
									</div>
								)
							case "amount_range":
								return (
									<div className="grid grid-cols-2 gap-2.5 p-3">
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
								)
						}
					}}
				</FilterPopover>
			))}
			{filtered && (
				<ActionButton variant="plain" size="compact" onClick={() => onChange(clearedCriteria(archiveFilters))}>
					Clear filters
				</ActionButton>
			)}
			<span className="ml-auto pl-2 text-fine whitespace-nowrap text-caption max-md:hidden">
				{documentCount === 1 ? "1 document" : `${documentCount} documents`}
			</span>
			{maintainedRecord && maintainedRecord.id === maintenance.recordId && (
				<TaxonomyRecordDialog record={maintainedRecord} onClose={() => setMaintenance(null)} onChange={onChange} />
			)}
		</div>
	)
}
