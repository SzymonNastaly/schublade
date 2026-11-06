import { Button, Dialog, Text } from "@cloudflare/kumo"
import { useMutation } from "@tanstack/react-query"
import { useState } from "react"
import type { Icon } from "@phosphor-icons/react"
import type { ComponentProps, ReactNode } from "react"

type ButtonVariant = ComponentProps<typeof Button>["variant"]

// Full width and 44 pixels high below md, where a finger operates them.
const touchSized = "w-full max-md:h-11 md:w-auto"

interface ActionConfirmationProperties {
	/** The label of the button that opens the dialog. */
	label: ReactNode
	icon: Icon
	variant: ButtonVariant
	disabled?: boolean
	className?: string
	title: string
	/** What the action does, named so the member can decide before anything changes. */
	description: ReactNode
	confirmationLabel: string
	confirmationVariant: ButtonVariant
	action: () => Promise<unknown>
	onCompleted: () => unknown
}

/** What deleting a document removes, as the confirmation of each deletion states it. */
export function documentDeletionDescription(title: string | null): string {
	return `Schublade deletes the original file, the extracted text, the search entry, and every field of “${title ?? "Untitled document"}”. You cannot undo this.`
}

/** A button for an action that cannot be undone, which runs the action only after the member confirms it in a dialog. */
export function ActionConfirmation({
	label,
	icon,
	variant,
	disabled,
	className = touchSized,
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
		<Dialog.Root role="alertdialog" open={open} onOpenChange={setOpen}>
			<Button variant={variant} icon={icon} className={className} disabled={disabled} onClick={() => setOpen(true)}>
				{label}
			</Button>
			<Dialog size="base" className="flex flex-col gap-4 p-6">
				<Dialog.Title className="text-lg font-semibold">{title}</Dialog.Title>
				<Dialog.Description className="text-kumo-subtle">{description}</Dialog.Description>
				{mutation.isError && <Text variant="error">{mutation.error.message}</Text>}
				<div className="flex flex-col-reverse gap-2 md:flex-row md:justify-end">
					<Button variant="secondary" className={touchSized} onClick={() => setOpen(false)}>
						Cancel
					</Button>
					<Button
						variant={confirmationVariant}
						icon={icon}
						className={touchSized}
						loading={mutation.isPending}
						onClick={() => mutation.mutate()}
					>
						{confirmationLabel}
					</Button>
				</div>
			</Dialog>
		</Dialog.Root>
	)
}
