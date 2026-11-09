import type { ReactNode } from "react"

/** The classes of a tab that rests on the top edge of the frame below it. */
export const frameTabClasses =
	"h-11 flex-none cursor-pointer rounded-t-tab border border-outline bg-inactive-tab px-3.5 text-fine whitespace-nowrap text-field-label data-[active]:border-b-surface data-[active]:bg-surface data-[active]:bg-none data-[active]:font-bold data-[active]:text-on-accent md:h-[34px]"

export const frameTabRowClasses = "relative -mb-px flex gap-[3px] overflow-x-auto pl-2 [scrollbar-width:none]"

export function FilterTabs({ label, children }: { label: string; children: ReactNode }) {
	return (
		<div role="group" aria-label={label} className={frameTabRowClasses}>
			{children}
		</div>
	)
}

export function FilterTab({
	selected,
	onSelect,
	children,
}: {
	selected: boolean
	onSelect: () => void
	children: ReactNode
}) {
	return (
		<button
			type="button"
			aria-pressed={selected}
			data-active={selected ? "" : undefined}
			onClick={onSelect}
			className={frameTabClasses}
		>
			{children}
		</button>
	)
}
