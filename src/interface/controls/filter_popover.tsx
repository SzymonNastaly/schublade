import { Popover } from "@base-ui/react/popover"
import { CaretDownIcon, XIcon } from "@phosphor-icons/react"
import { useState } from "react"
import type { ReactNode } from "react"

const triggerClasses =
	"inline-flex h-11 max-w-60 flex-none cursor-pointer items-center gap-1.5 rounded-control border px-3 text-fine whitespace-nowrap md:h-8.5"

interface FilterPopoverProperties {
	label: string
	/** The value the filter applies, or undefined while it applies none. */
	value: string | undefined
	onClear: () => void
	/** The content of the popover, given a function that closes it. */
	children: (close: () => void) => ReactNode
}

/**
 * A button that names a filter and opens its controls below it. While the filter applies, the
 * button shows the value in the colours of a chip, with a button joined to it that clears it.
 */
export function FilterPopover({ label, value, onClear, children }: FilterPopoverProperties) {
	const [open, setOpen] = useState(false)
	return (
		<Popover.Root open={open} onOpenChange={setOpen}>
			<span className="inline-flex flex-none">
				<Popover.Trigger
					className={
						value === undefined
							? `${triggerClasses} border-control-border bg-control text-control-foreground hover:border-control-foreground`
							: `${triggerClasses} rounded-r-none border-chip-border bg-chip font-bold text-on-accent`
					}
				>
					{value === undefined ? (
						label
					) : (
						<span className="truncate">
							{label}: {value}
						</span>
					)}
					<CaretDownIcon size={11} weight="bold" className="flex-none" />
				</Popover.Trigger>
				{value !== undefined && (
					<button
						type="button"
						aria-label={`Clear the ${label} filter`}
						onClick={onClear}
						className="inline-flex h-11 w-9 flex-none cursor-pointer items-center justify-center rounded-r-control border border-l-0 border-chip-border bg-chip text-on-accent hover:bg-documents-hover md:h-8.5 md:w-7"
					>
						<XIcon size={11} weight="bold" />
					</button>
				)}
			</span>
			<Popover.Portal>
				<Popover.Positioner side="bottom" align="start" sideOffset={4} collisionPadding={8}>
					<Popover.Popup
						aria-label={label}
						className="flex max-h-[min(26rem,var(--available-height))] w-72 max-w-[var(--available-width)] flex-col overflow-hidden rounded-field border border-documents-border bg-surface text-body shadow-dialog"
					>
						{children(() => setOpen(false))}
					</Popover.Popup>
				</Popover.Positioner>
			</Popover.Portal>
		</Popover.Root>
	)
}
