import { Badge, Button, Empty, Text } from "@cloudflare/kumo"
import { SealCheckIcon } from "@phosphor-icons/react"
import { Link, createFileRoute } from "@tanstack/react-router"
import { useState } from "react"
import { touchSized } from "../interface/action_confirmation"
import { ArchiveNavigation } from "../interface/archive_navigation"
import { NewSenderConfirmation } from "../interface/new_sender_confirmation"
import { selectNewSenders, summarizeVerificationEntry, verificationEntryKey } from "../interface/verification_entries"
import { retrieveVerificationItems } from "../utilities/server_functions"
import type { VerificationItem } from "../archive/verification_items"

export const Route = createFileRoute("/verification")({
	loader: () => retrieveVerificationItems(),
	component: PendingVerificationPage,
})

function EntryRow({ item }: { item: VerificationItem }) {
	const { badge, subject, note } = summarizeVerificationEntry(item)
	return (
		<li>
			<Link
				to="/verification/review"
				search={{ entry: verificationEntryKey(item) }}
				className="flex min-h-11 w-full min-w-0 flex-wrap items-center gap-x-3 gap-y-1 rounded-lg px-2 py-2 hover:bg-kumo-tint active:bg-kumo-tint"
			>
				<Badge variant={badge.variant}>{badge.label}</Badge>
				<span className="min-w-0 font-medium wrap-anywhere">{subject}</span>
				<span className="text-sm text-kumo-subtle">{note}</span>
			</Link>
		</li>
	)
}

function PendingVerificationPage() {
	const items = Route.useLoaderData()
	const navigate = Route.useNavigate()
	const [confirmedSenderCount, setConfirmedSenderCount] = useState<number | null>(null)
	const newSenders = selectNewSenders(items)
	return (
		<main className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 pb-[max(1.5rem,env(safe-area-inset-bottom))] md:px-6 md:py-12">
			<div className="flex flex-wrap items-center justify-between gap-4">
				<Text variant="heading1" as="h1">
					Pending verification
				</Text>
				<ArchiveNavigation />
			</div>
			{confirmedSenderCount !== null && (
				<p role="status" className="text-kumo-subtle">
					{confirmedSenderCount === 1 ? "1 sender" : `${confirmedSenderCount} senders`} confirmed
				</p>
			)}
			{items.length === 0 ? (
				<Empty
					icon={<SealCheckIcon size={32} />}
					title="Nothing awaits verification"
					description="Every document is archived and searchable. New senders, unreadable fields, attachments, and failed documents appear here."
				/>
			) : (
				<>
					<div className="flex flex-col gap-2 md:flex-row">
						<Button
							variant="primary"
							className={touchSized}
							onClick={() => void navigate({ to: "/verification/review" })}
						>
							Review {items.length === 1 ? "1 item" : `${items.length} items`}
						</Button>
						{newSenders.senders.length > 0 && (
							<NewSenderConfirmation {...newSenders} onConfirmed={setConfirmedSenderCount} />
						)}
					</div>
					<ul className="-mx-2 flex flex-col">
						{items.map((item) => (
							<EntryRow key={verificationEntryKey(item)} item={item} />
						))}
					</ul>
				</>
			)}
		</main>
	)
}
