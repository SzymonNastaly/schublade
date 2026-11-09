import { XIcon } from "@phosphor-icons/react"
import { useId, useState } from "react"

/** The tags after adding typed text. Blank text, a tag already present, and a tag over the limit change nothing. */
export function appendTag(tags: ReadonlyArray<string>, text: string, limit: number): ReadonlyArray<string> {
	const tag = text.trim()
	const present = tags.some((existing) => existing.toLocaleLowerCase() === tag.toLocaleLowerCase())
	return tag === "" || present || tags.length >= limit ? tags : [...tags, tag]
}

interface TagFieldProperties {
	label: string
	value: ReadonlyArray<string>
	onChange: (tags: Array<string>) => void
	limit: number
}

/** Free text that becomes a tag on Enter, on a comma, or when the field loses focus. */
export function TagField({ label, value, onChange, limit }: TagFieldProperties) {
	const inputIdentifier = useId()
	const [draft, setDraft] = useState("")
	const commitDraft = () => {
		onChange([...appendTag(value, draft, limit)])
		setDraft("")
	}
	return (
		<div className="flex min-w-0 flex-col gap-1 text-fine text-field-label">
			<label htmlFor={inputIdentifier}>{label}</label>
			<div className="flex min-h-11 flex-wrap items-center gap-1.5 rounded-field border border-field-border bg-surface p-1 md:min-h-9">
				{value.map((tag) => (
					<span
						key={tag}
						className="inline-flex max-w-full items-center gap-1 rounded-badge border border-chip-border bg-chip py-0.5 pr-0.5 pl-2 text-on-accent"
					>
						<span className="truncate">{tag}</span>
						<button
							type="button"
							aria-label={`Remove tag ${tag}`}
							className="flex size-6 cursor-pointer items-center justify-center"
							onClick={() => onChange(value.filter((other) => other !== tag))}
						>
							<XIcon size={10} weight="bold" />
						</button>
					</span>
				))}
				{value.length < limit && (
					<input
						id={inputIdentifier}
						value={draft}
						onChange={(event) => setDraft(event.target.value)}
						onBlur={commitDraft}
						onKeyDown={(event) => {
							if (event.key === "Enter" || event.key === ",") {
								event.preventDefault()
								commitDraft()
							} else if (event.key === "Backspace" && draft === "") {
								onChange(value.slice(0, -1))
							}
						}}
						className="h-7 min-w-20 flex-1 bg-transparent px-1 text-body text-foreground outline-none"
					/>
				)}
			</div>
		</div>
	)
}
