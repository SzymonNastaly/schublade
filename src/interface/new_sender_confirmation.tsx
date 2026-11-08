import { Button, Checkbox, Dialog, Text } from "@cloudflare/kumo"
import { CheckIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { submitTaxonomyConfirmations } from "../utilities/server_functions"
import { touchSized } from "./action_confirmation"
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
			<Dialog.Title className="text-lg font-semibold">Confirm new senders</Dialog.Title>
			<Dialog.Description className="text-kumo-subtle">Untick any that look wrong.</Dialog.Description>
			<ul className="flex min-h-0 flex-col overflow-y-auto">
				{senders.map(({ id, name, documentCount }) => (
					<li key={id}>
						<label className="flex min-h-11 cursor-pointer items-center gap-3 py-1 pl-1">
							<Checkbox
								aria-label={name}
								checked={!untickedIds.has(id)}
								onCheckedChange={(ticked) => setTicked(id, ticked)}
							/>
							<span className="min-w-0 flex-1 wrap-anywhere">{name}</span>
							<span className="shrink-0 pr-1 text-sm text-kumo-subtle tabular-nums">
								{documentCountLabel(documentCount)}
							</span>
						</label>
					</li>
				))}
			</ul>
			{unknownSenderLeftOut && (
				<Text variant="secondary">
					The sender Unknown is left out, because the classifier invents it for unreadable documents.
				</Text>
			)}
			{confirmation.isError && <Text variant="error">{confirmation.error.message}</Text>}
			<div className="flex flex-col-reverse gap-2 md:flex-row md:justify-end">
				<Button variant="secondary" className={touchSized} onClick={onClose}>
					Cancel
				</Button>
				<Button
					variant="primary"
					icon={CheckIcon}
					className={touchSized}
					disabled={tickedIds.length === 0}
					loading={confirmation.isPending}
					onClick={() => confirmation.mutate()}
				>
					Confirm {tickedIds.length}
				</Button>
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
		<Dialog.Root open={open} onOpenChange={setOpen}>
			<Button variant="secondary" icon={CheckIcon} className={touchSized} onClick={() => setOpen(true)}>
				Confirm {senderCount} new {senderCount === 1 ? "sender" : "senders"}
			</Button>
			<Dialog size="base" className="flex max-h-[calc(100dvh-4rem)] flex-col gap-4 p-6 sm:max-h-[calc(100dvh-8rem)]">
				<SenderChecklist {...selection} onClose={() => setOpen(false)} onConfirmed={onConfirmed} />
			</Dialog>
		</Dialog.Root>
	)
}
