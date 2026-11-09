import { CheckIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { submitTaxonomyConfirmations } from "../utilities/server_functions"
import { ActionButton } from "./controls/action_button"
import { FailureMessage } from "./controls/form_fields"
import { ModalDialog } from "./controls/modal_dialog"
import { documentCountLabel } from "./verification_entries"
import type { NewSenderSelection } from "./verification_entries"

interface SenderChecklistProperties extends NewSenderSelection {
	onClose: () => void
	onConfirmed: (confirmedCount: number) => void
}

/** Mounts each time the dialog opens, so every sender starts ticked. */
function SenderChecklist({ senders, unknownSenderLeftOut, onClose, onConfirmed }: SenderChecklistProperties) {
	const router = useRouter()
	const [untickedIds, setUntickedIds] = useState<ReadonlySet<string>>(new Set())
	const tickedIds = senders.flatMap(({ id }) => (untickedIds.has(id) ? [] : [id]))
	const confirmation = useMutation({
		mutationFn: () => submitTaxonomyConfirmations({ data: { kind: "sender", recordIds: tickedIds } }),
		onSuccess: (confirmedCount) => {
			onConfirmed(confirmedCount)
			onClose()
			void router.invalidate()
		},
	})
	function setTicked(id: string, ticked: boolean) {
		const unticked = new Set(untickedIds)
		if (ticked) unticked.delete(id)
		else unticked.add(id)
		setUntickedIds(unticked)
	}
	return (
		<>
			<ul className="flex max-h-[45dvh] flex-col overflow-y-auto rounded-table border border-table-border">
				{senders.map(({ id, name, documentCount }) => (
					<li key={id} className="border-b border-dotted border-row-rule last:border-b-0">
						<label className="flex min-h-11 cursor-pointer items-center gap-2.5 px-3 py-1">
							<input
								type="checkbox"
								className="size-[18px] flex-none accent-primary"
								checked={!untickedIds.has(id)}
								onChange={(event) => setTicked(id, event.target.checked)}
							/>
							<span className="min-w-0 flex-1 font-bold wrap-anywhere">{name}</span>
							<span className="flex-none text-fine text-caption">{documentCountLabel(documentCount)}</span>
						</label>
					</li>
				))}
			</ul>
			{unknownSenderLeftOut && (
				<p className="text-caption">
					The sender Unknown is left out, because the classifier invents it for unreadable documents.
				</p>
			)}
			{confirmation.isError && <FailureMessage>{confirmation.error.message}</FailureMessage>}
			<div className="flex flex-col-reverse gap-2 md:flex-row md:justify-end">
				<ActionButton variant="secondary" stretchOnPhone onClick={onClose}>
					Cancel
				</ActionButton>
				<ActionButton
					variant="primary"
					icon={CheckIcon}
					stretchOnPhone
					disabled={tickedIds.length === 0}
					pending={confirmation.isPending}
					onClick={() => confirmation.mutate()}
				>
					Confirm {tickedIds.length}
				</ActionButton>
			</div>
		</>
	)
}

export function NewSenderConfirmation({
	onConfirmed,
	...selection
}: NewSenderSelection & { onConfirmed: (confirmedCount: number) => void }) {
	const [open, setOpen] = useState(false)
	const senderCount = selection.senders.length
	return (
		<>
			<ActionButton variant="secondary" icon={CheckIcon} stretchOnPhone onClick={() => setOpen(true)}>
				Confirm {senderCount} new {senderCount === 1 ? "sender" : "senders"}
			</ActionButton>
			<ModalDialog
				open={open}
				onOpenChange={setOpen}
				section="verification"
				title="Confirm new senders"
				description="Untick any that look wrong."
			>
				{open && <SenderChecklist {...selection} onClose={() => setOpen(false)} onConfirmed={onConfirmed} />}
			</ModalDialog>
		</>
	)
}
