import { Empty, Text } from "@cloudflare/kumo"
import { SealCheckIcon } from "@phosphor-icons/react"
import { Link, createFileRoute } from "@tanstack/react-router"
import { useState } from "react"
import { ArchiveNavigation } from "../interface/archive_navigation"
import { DocumentOriginal } from "../interface/document_original"
import {
	documentCountLabel,
	locateReviewStep,
	reviewedDocument,
	verificationEntryKey,
} from "../interface/verification_entries"
import { VerificationEntryControls } from "../interface/verification_entry_controls"
import { listArchiveFacets, retrieveVerificationItems } from "../utilities/server_functions"
import type { ArchiveFacets } from "../archive/document_listing"
import type { VerificationItem } from "../archive/verification_items"

export const Route = createFileRoute("/verification_/review")({
	validateSearch: (search: Record<string, unknown>): { entry?: string } =>
		typeof search.entry === "string" ? { entry: search.entry } : {},
	loader: async () => {
		const [items, facets] = await Promise.all([retrieveVerificationItems(), listArchiveFacets()])
		return { items, facets }
	},
	component: VerificationReviewPage,
})

const quietLink = "text-kumo-link underline underline-offset-2 max-md:inline-flex max-md:min-h-11 max-md:items-center"

function skippedEntriesNote(skippedCount: number): string {
	if (skippedCount === 0) return "Every entry is resolved."
	return skippedCount === 1
		? "The entry you skipped stays pending."
		: `The ${skippedCount} entries you skipped stay pending.`
}

function ReviewedEntry({ item, facets }: { item: VerificationItem; facets: ArchiveFacets }) {
	const document = reviewedDocument(item)
	const controls = <VerificationEntryControls item={item} facets={facets} />
	if (document === undefined) return controls
	return (
		<div className="grid grid-cols-1 gap-6 md:grid-cols-2 md:items-start">
			<DocumentOriginal document={document} />
			<div className="flex min-w-0 flex-col gap-4">
				{item.reason === "new_taxonomy_record" && item.documents.length > 1 && (
					<Text variant="secondary">Appears on {documentCountLabel(item.documents.length)}. This is the newest.</Text>
				)}
				{controls}
			</div>
		</div>
	)
}

function VerificationReviewPage() {
	const { items, facets } = Route.useLoaderData()
	const { entry: requestedKey } = Route.useSearch()
	const [entryOrder] = useState(() => items.map(verificationEntryKey))
	const [skippedKeys, setSkippedKeys] = useState<ReadonlySet<string>>(new Set())
	const step = locateReviewStep({ items, entryOrder, skippedKeys, requestedKey })
	return (
		<main className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 pb-[max(1.5rem,env(safe-area-inset-bottom))] md:px-6 md:py-12">
			{step.kind === "finished" ? (
				<>
					<Text variant="heading1" as="h1">
						Pending verification
					</Text>
					<Empty
						icon={<SealCheckIcon size={32} />}
						title="Nothing left to review"
						description={skippedEntriesNote(step.skippedCount)}
						contents={
							<Link to="/verification" className={quietLink}>
								Back to Pending verification
							</Link>
						}
					/>
				</>
			) : (
				<>
					<header className="flex items-center justify-between gap-4">
						<Text variant="heading2" as="h1">
							{step.ordinal} of {step.total}
						</Text>
						<Link
							to="/verification/review"
							search={{ entry: step.successorKey }}
							className={quietLink}
							onClick={() => setSkippedKeys(new Set(skippedKeys).add(verificationEntryKey(step.item)))}
						>
							Skip
						</Link>
					</header>
					{/* Keyed so an entry's half-filled form and drawn document never carry over to the next one. */}
					<ReviewedEntry key={verificationEntryKey(step.item)} item={step.item} facets={facets} />
				</>
			)}
			<ArchiveNavigation />
		</main>
	)
}
