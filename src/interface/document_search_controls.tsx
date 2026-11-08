import { Button, Combobox, Input, InputGroup, Loader, Popover } from "@cloudflare/kumo"
import { CaretDownIcon, FunnelIcon, MagnifyingGlassIcon, XIcon } from "@phosphor-icons/react"
import { useEffect, useRef, useState } from "react"
import { activeFilters, personOptions } from "./active_filter_presentation"
import type { ReactNode } from "react"
import type { ArchiveFacets, FacetOption } from "../archive/document_listing"
import type { SearchCriteria } from "../search/search_criteria"

const TYPING_PAUSE_MILLISECONDS = 350
// Kumo sets text at 14 px, and iOS Safari zooms the page when it focuses a field below 16 px.
const TOUCH_FIELD = "max-md:h-11"

type CriteriaChange = (changes: Partial<SearchCriteria>) => void

/**
 * Text that commits after a pause in typing, so each keystroke does not start a search. A
 * committed value that changes elsewhere, such as through Clear, replaces the text.
 */
function useCommittedText(committed: string, onCommit: (text: string) => void) {
	const [text, setText] = useState(committed)
	const [previousCommitted, setPreviousCommitted] = useState(committed)
	if (committed !== previousCommitted) {
		setPreviousCommitted(committed)
		if (committed !== text.trim()) setText(committed)
	}
	const commit = useRef(onCommit)
	commit.current = onCommit
	useEffect(() => {
		if (text.trim() === committed) return
		const timer = setTimeout(() => commit.current(text.trim()), TYPING_PAUSE_MILLISECONDS)
		return () => clearTimeout(timer)
	}, [text, committed])
	return [text, setText] as const
}

function SearchInput({ query, searching, onChange }: { query: string; searching: boolean; onChange: CriteriaChange }) {
	const input = useRef<HTMLInputElement>(null)
	const [text, setText] = useCommittedText(query, (committed) =>
		onChange({ query: committed === "" ? undefined : committed }),
	)
	useEffect(() => {
		const focusSearch = (event: KeyboardEvent) => {
			const target = event.target instanceof HTMLElement ? event.target : null
			const editing =
				target !== null && (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName))
			const shortcut = (event.key === "k" && (event.metaKey || event.ctrlKey)) || (event.key === "/" && !editing)
			if (!shortcut) return
			event.preventDefault()
			input.current?.focus()
			input.current?.select()
		}
		window.addEventListener("keydown", focusSearch)
		return () => window.removeEventListener("keydown", focusSearch)
	}, [])
	return (
		<InputGroup size="lg" className="w-full">
			<InputGroup.Addon>
				<MagnifyingGlassIcon />
			</InputGroup.Addon>
			<InputGroup.Input
				ref={input}
				type="search"
				aria-label="Search documents"
				placeholder="Search documents"
				value={text}
				onChange={(event) => setText(event.target.value)}
			/>
			<InputGroup.Addon align="end">
				{searching ? (
					<Loader />
				) : (
					<kbd className="hidden rounded border border-kumo-hairline bg-kumo-base px-1.5 py-0.5 text-xs md:inline">
						/
					</kbd>
				)}
			</InputGroup.Addon>
		</InputGroup>
	)
}

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
	/** True while the results for changed criteria load. */
	searching: boolean
	onChange: CriteriaChange
}

export function DocumentSearchControls({ criteria, facets, searching, onChange }: DocumentSearchControlsProperties) {
	const [filtersShown, setFiltersShown] = useState(false)
	const filters = activeFilters(criteria, facets)
	return (
		<div className="flex flex-col gap-3">
			<div className="flex gap-2">
				<SearchInput query={criteria.query ?? ""} searching={searching} onChange={onChange} />
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
