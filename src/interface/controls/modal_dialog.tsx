import { Dialog } from "@base-ui/react/dialog"
import { panelHeadingClasses } from "./section_panel"
import type { ArchiveSection } from "../archive_sections"
import type { ReactNode } from "react"

interface ModalDialogProperties {
	open: boolean
	onOpenChange: (open: boolean) => void
	section: ArchiveSection
	title: string
	description: ReactNode
	/** Asks about something irreversible, so a press outside the dialog does not dismiss it. */
	alert?: boolean
	children: ReactNode
}

/** A centred box from the md breakpoint upward, and a sheet along the bottom edge of a phone. */
export function ModalDialog({
	open,
	onOpenChange,
	section,
	title,
	description,
	alert = false,
	children,
}: ModalDialogProperties) {
	return (
		<Dialog.Root open={open} onOpenChange={onOpenChange} disablePointerDismissal={alert}>
			<Dialog.Portal>
				<Dialog.Backdrop className="fixed inset-0 bg-dialog-backdrop" />
				<Dialog.Popup
					role={alert ? "alertdialog" : "dialog"}
					className="fixed inset-x-0 bottom-0 max-h-[85dvh] overflow-y-auto rounded-tr-panel bg-surface pb-[env(safe-area-inset-bottom)] shadow-dialog md:inset-x-auto md:top-44 md:bottom-auto md:left-1/2 md:max-h-[calc(100dvh-13rem)] md:w-full md:max-w-[480px] md:-translate-x-1/2 md:rounded-b-field md:pb-0"
				>
					<Dialog.Title className={`px-3.5 py-2.5 text-sm font-bold ${panelHeadingClasses(section)}`}>
						{title}
					</Dialog.Title>
					<div className="flex flex-col gap-3 p-4">
						<Dialog.Description className="text-field-label">{description}</Dialog.Description>
						{children}
					</div>
				</Dialog.Popup>
			</Dialog.Portal>
		</Dialog.Root>
	)
}
