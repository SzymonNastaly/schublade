import { useMutation } from "@tanstack/react-query"
import { useState } from "react"
import { ActionButton } from "./controls/action_button"
import { FailureMessage } from "./controls/form_fields"
import { ModalDialog } from "./controls/modal_dialog"
import type { ArchiveSection } from "./archive_sections"
import type { ComponentProps, ReactNode } from "react"

// Full width and 44 pixels high below md, where a finger operates them.
export const touchSized = "w-full max-md:h-11 md:w-auto"

interface ActionConfirmationProperties {
	/** The control that opens the dialog. */
	trigger: (open: () => void) => ReactNode
	section?: ArchiveSection
	title: string
	/** What the action does, named so the member can decide before anything changes. */
	description: ReactNode
	confirmationLabel: string
	confirmationVariant: ComponentProps<typeof ActionButton>["variant"]
	action: () => Promise<unknown>
	onCompleted: () => unknown
}

/** What deleting a document removes, as the confirmation of each deletion states it. */
export function documentDeletionDescription(title: string | null): string {
	return `Schublade deletes the original file, the extracted text, the search entry, and every field of “${title ?? "Untitled document"}”. You cannot undo this.`
}

/** A control for an action that cannot be undone, which runs the action only after the member confirms it in a dialog. */
export function ActionConfirmation({
	trigger,
	section = "documents",
	title,
	description,
	confirmationLabel,
	confirmationVariant,
	action,
	onCompleted,
}: ActionConfirmationProperties) {
	const [open, setOpen] = useState(false)
	const mutation = useMutation({
		mutationFn: action,
		onSuccess: () => {
			setOpen(false)
			void onCompleted()
		},
	})
	return (
		<>
			{trigger(() => setOpen(true))}
			<ModalDialog open={open} onOpenChange={setOpen} section={section} title={title} description={description} alert>
				{mutation.isError && <FailureMessage>{mutation.error.message}</FailureMessage>}
				<div className="flex flex-col-reverse gap-2 md:flex-row md:justify-end">
					<ActionButton variant="secondary" stretchOnPhone onClick={() => setOpen(false)}>
						Cancel
					</ActionButton>
					<ActionButton
						variant={confirmationVariant}
						stretchOnPhone
						pending={mutation.isPending}
						onClick={() => mutation.mutate()}
					>
						{confirmationLabel}
					</ActionButton>
				</div>
			</ModalDialog>
		</>
	)
}
