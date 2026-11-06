import { Button, Input, InputGroup, Loader, Select } from "@cloudflare/kumo"
import { FunnelIcon, MagnifyingGlassIcon, XIcon } from "@phosphor-icons/react"
import { useEffect, useRef, useState } from "react"
import { HOUSEHOLD_PERSON } from "../search/search_index_item"
import type { ArchiveFacets } from "../archive/document_listing"
import type { SearchCriteria } from "../search/search_criteria"

const TYPING_PAUSE_MILLISECONDS = 350
const ANY_OPTION = "any"

type CriteriaChange = (changes: Partial<SearchCriteria>) => void

/**
 * Text that commits after a pause in typing, so each keystroke does not start a search. A
 * committed value that changes elsewhere, such as through Clear filters, replaces the text.
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
			className="w-full min-w-0"
			type="number"
			inputMode="decimal"
			min={0}
			step={0.01}
			value={text}
			onChange={(event) => setText(event.target.value)}
		/>
	)
}

function FacetSelect({
	label,
	anyLabel,
	options,
	value,
	onValueChange,
}: {
	label: string
	anyLabel: string
	options: Array<{ id: string; name: string }>
	value: string | undefined
	onValueChange: (value: string | undefined) => void
}) {
	// The select renders no option for a null value, so "any" is an option of its own.
	return (
		<Select<string>
			label={label}
			className="w-full"
			value={value ?? ANY_OPTION}
			onValueChange={(selected) => onValueChange(selected === null || selected === ANY_OPTION ? undefined : selected)}
			items={[
				{ value: ANY_OPTION, label: anyLabel },
				...options.map((option) => ({ value: option.id, label: option.name })),
			]}
		/>
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
	const { query, ...filters } = criteria
	// The parsed criteria hold only the parameters that are present.
	const activeFilterCount = Object.keys(filters).length
	const clearedFilters: Partial<SearchCriteria> = Object.fromEntries(
		Object.keys(filters).map((key) => [key, undefined]),
	)
	return (
		<div className="flex flex-col gap-3">
			<div className="flex gap-2">
				<SearchInput query={query ?? ""} searching={searching} onChange={onChange} />
				<Button
					className="md:hidden"
					variant={activeFilterCount > 0 ? "primary" : "secondary"}
					size="lg"
					icon={FunnelIcon}
					aria-label="Filters"
					aria-expanded={filtersShown}
					onClick={() => setFiltersShown(!filtersShown)}
				>
					{activeFilterCount > 0 ? activeFilterCount : ""}
				</Button>
			</div>
			<div className={`${filtersShown ? "grid" : "hidden"} grid-cols-2 gap-3 md:grid md:grid-cols-4`}>
				{facets.members.length > 1 && (
					<FacetSelect
						label="Person"
						anyLabel="Everyone"
						options={[...facets.members, { id: HOUSEHOLD_PERSON, name: "Household" }]}
						value={criteria.person}
						onValueChange={(person) => onChange({ person })}
					/>
				)}
				<FacetSelect
					label="Sender"
					anyLabel="Any sender"
					options={facets.senders}
					value={criteria.sender}
					onValueChange={(sender) => onChange({ sender })}
				/>
				<FacetSelect
					label="Category"
					anyLabel="Any category"
					options={facets.categories}
					value={criteria.category}
					onValueChange={(category) => onChange({ category })}
				/>
				<FacetSelect
					label="Tag"
					anyLabel="Any tag"
					options={facets.tags}
					value={criteria.tag}
					onValueChange={(tag) => onChange({ tag })}
				/>
				<Input
					label="Dated from"
					aria-label="Dated from"
					className="w-full min-w-0"
					type="date"
					value={criteria.earliestDocumentDate ?? ""}
					onChange={(event) => onChange({ earliestDocumentDate: event.target.value || undefined })}
				/>
				<Input
					label="Dated until"
					aria-label="Dated until"
					className="w-full min-w-0"
					type="date"
					value={criteria.latestDocumentDate ?? ""}
					onChange={(event) => onChange({ latestDocumentDate: event.target.value || undefined })}
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
				{activeFilterCount > 0 && (
					<Button
						variant="ghost"
						icon={XIcon}
						className="col-span-2 md:col-span-4 md:justify-self-start"
						onClick={() => onChange(clearedFilters)}
					>
						Clear filters
					</Button>
				)}
			</div>
		</div>
	)
}
