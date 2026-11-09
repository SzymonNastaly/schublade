import { Button, Combobox, Input, Popover } from "@cloudflare/kumo"
import { CaretDownIcon, FunnelIcon, XIcon } from "@phosphor-icons/react"
import { useState } from "react"
import { activeFilters, personOptions } from "./active_filter_presentation"
import { useCommittedText } from "./committed_text"
import type { ReactNode } from "react"
import type { ArchiveFacets, FacetOption } from "../archive/document_listing"
import type { SearchCriteria } from "../search/search_criteria"

// Kumo sets text at 14 px, and iOS Safari zooms the page when it focuses a field below 16 px.
const TOUCH_FIELD = "max-md:h-11"

type CriteriaChange = (changes: Partial<SearchCriteria>) => void

function AmountInput({
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
		<Input
			label={label}
			aria-label={label}
			className={`w-full min-w-0 ${TOUCH_FIELD}`}
			type="number"
			inputMode="decimal"
			min={0}
			step={0.01}
			value={text}
			onChange={(event) => setText(event.target.value)}
		/>
	)
}

/** Base UI clones this element into the trigger of a filter control. */
function filterTrigger(label: string) {
	return (
		<Button variant="secondary" className="w-full justify-between max-md:h-11 md:w-auto">
			{label}
			<CaretDownIcon />
		</Button>
	)
}

function FacetCombobox({
	label,
	options,
	value,
	onValueChange,
}: {
	label: string
	options: Array<FacetOption>
	value: string | undefined
	onValueChange: (value: string | undefined) => void
}) {
	const findLabel = `Find ${label.toLowerCase()}`
	return (
		<Combobox<FacetOption>
			items={options}
			value={options.find((option) => option.id === value) ?? null}
			onValueChange={(option) => onValueChange(option?.id)}
			itemToStringLabel={(option) => option.name}
		>
			<Combobox.Trigger aria-label={label} render={filterTrigger(label)} />
			<Combobox.Content className="w-72">
				<Combobox.Input aria-label={findLabel} placeholder={findLabel} className={TOUCH_FIELD} />
				<Combobox.Empty>No matches</Combobox.Empty>
				<Combobox.List>
					{(option: FacetOption) => (
						<Combobox.Item
							key={option.id}
							value={option}
							className="grid-cols-[minmax(0,1fr)_16px] items-center max-md:min-h-11"
						>
							<span className="flex items-baseline justify-between gap-3">
								<span className="truncate">{option.name}</span>
								<span className="text-sm text-kumo-subtle tabular-nums">{option.documentCount}</span>
							</span>
						</Combobox.Item>
					)}
				</Combobox.List>
			</Combobox.Content>
		</Combobox>
	)
}

function FilterPopover({ label, children }: { label: string; children: ReactNode }) {
	return (
		<Popover.Root>
			<Popover.Trigger render={filterTrigger(label)} />
			{/* Stays mounted, so that an amount typed just before the popover closes still commits. */}
			<Popover.Portal keepMounted>
				<Popover.Positioner align="start" sideOffset={4}>
					<Popover.Popup className="w-72 max-w-(--available-width) gap-3">{children}</Popover.Popup>
				</Popover.Positioner>
			</Popover.Portal>
		</Popover.Root>
	)
}

interface DocumentSearchControlsProperties {
	criteria: SearchCriteria
	facets: ArchiveFacets
	onChange: CriteriaChange
}

export function DocumentSearchControls({ criteria, facets, onChange }: DocumentSearchControlsProperties) {
	const [filtersShown, setFiltersShown] = useState(false)
	const filters = activeFilters(criteria, facets)
	return (
		<div className="flex flex-col gap-3">
			<div className="flex gap-2">
				<Button
					className="md:hidden"
					variant={filters.length > 0 ? "primary" : "secondary"}
					size="lg"
					icon={FunnelIcon}
					aria-label="Filters"
					aria-expanded={filtersShown}
					onClick={() => setFiltersShown(!filtersShown)}
				>
					{filters.length > 0 ? filters.length : ""}
				</Button>
			</div>
			<div className={`${filtersShown ? "grid" : "hidden"} grid-cols-2 gap-2 md:flex md:flex-wrap`}>
				{facets.members.length > 1 && (
					<FacetCombobox
						label="Person"
						options={personOptions(facets)}
						value={criteria.person}
						onValueChange={(person) => onChange({ person })}
					/>
				)}
				<FacetCombobox
					label="Sender"
					options={facets.senders}
					value={criteria.sender}
					onValueChange={(sender) => onChange({ sender })}
				/>
				<FacetCombobox
					label="Category"
					options={facets.categories}
					value={criteria.category}
					onValueChange={(category) => onChange({ category })}
				/>
				<FilterPopover label="Date">
					<Input
						label="From"
						aria-label="Dated from"
						className={`w-full min-w-0 ${TOUCH_FIELD}`}
						type="date"
						value={criteria.earliestDocumentDate ?? ""}
						onChange={(event) => onChange({ earliestDocumentDate: event.target.value || undefined })}
					/>
					<Input
						label="Until"
						aria-label="Dated until"
						className={`w-full min-w-0 ${TOUCH_FIELD}`}
						type="date"
						value={criteria.latestDocumentDate ?? ""}
						onChange={(event) => onChange({ latestDocumentDate: event.target.value || undefined })}
					/>
				</FilterPopover>
				<FilterPopover label="More">
					<FacetCombobox
						label="Tag"
						options={facets.tags}
						value={criteria.tag}
						onValueChange={(tag) => onChange({ tag })}
					/>
					<AmountInput
						label="Minimum amount"
						amount={criteria.minimumAmount}
						onCommit={(minimumAmount) => onChange({ minimumAmount })}
					/>
					<AmountInput
						label="Maximum amount"
						amount={criteria.maximumAmount}
						onCommit={(maximumAmount) => onChange({ maximumAmount })}
					/>
				</FilterPopover>
			</div>
			{filters.length > 0 && (
				<div className="flex flex-wrap items-center gap-2">
					{filters.map(({ criterion, label }) => (
						<Button
							key={criterion}
							size="sm"
							className="max-w-full max-md:h-11"
							aria-label={`Remove filter ${label}`}
							onClick={() => onChange({ [criterion]: undefined })}
						>
							<span className="truncate">{label}</span>
							<XIcon className="shrink-0" />
						</Button>
					))}
					<Button
						variant="ghost"
						size="sm"
						className="max-md:h-11"
						onClick={() => onChange(Object.fromEntries(filters.map(({ criterion }) => [criterion, undefined])))}
					>
						Clear
					</Button>
				</div>
			)}
		</div>
	)
}
