import { Banner, Button, Input, LayerCard, Select, Text } from "@cloudflare/kumo"
import { CaretRightIcon, CheckIcon, GitMergeIcon, PencilSimpleIcon, TrashIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { Link, useRouter } from "@tanstack/react-router"
import { useState } from "react"
import {
	submitDocumentDeletion,
	submitDocumentRevision,
	submitTaxonomyConfirmation,
	submitTaxonomyDeletion,
	submitTaxonomyMerge,
	submitTaxonomyRename,
} from "../utilities/server_functions"
import { ActionConfirmation, documentDeletionDescription, touchSized } from "./action_confirmation"
import { StatusBadge } from "./controls/status_badge"
import { formatDocumentDate } from "./document_formatting"
import { documentFailureSentences } from "./document_status_presentation"
import { FailedDocumentActions } from "./upload_tray"
import { requiredFieldLabels, summarizeVerificationEntry } from "./verification_entries"
import type { ArchiveFacets } from "../archive/document_listing"
import type { TaxonomyKind } from "../archive/taxonomy_maintenance"
import type { VerificationDocument, VerificationItem } from "../archive/verification_items"
import type { RequiredFieldKey } from "../ingestion/verification_assessment"
import type { ReactNode } from "react"

const kindPresentations: Record<TaxonomyKind, { label: string; facet: "senders" | "categories" | "tags" }> = {
	sender: { label: "sender", facet: "senders" },
	category: { label: "category", facet: "categories" },
	tag: { label: "tag", facet: "tags" },
}

const requiredFieldInputTypes: Record<RequiredFieldKey, "date" | "number"> = { document_date: "date", amount: "number" }

/** Runs an action, then reloads the entries and the navigation count, which drops the resolved entry. */
function useVerificationAction<TInput, TResult = unknown>(action: (input: TInput) => Promise<TResult>) {
	const router = useRouter()
	return useMutation({ mutationFn: action, onSuccess: () => router.invalidate() })
}

/** States how many documents a merge moves, such as "3 documents move". */
function movedDocumentCount(count: number): string {
	if (count === 0) return "No document moves"
	return count === 1 ? "1 document moves" : `${count} documents move`
}

function documentLine(document: VerificationDocument): string {
	const documentDate = document.documentDate === null ? null : formatDocumentDate(document.documentDate)
	return [document.title ?? "Untitled document", document.senderName, documentDate]
		.filter((part) => part !== null)
		.join(" · ")
}

// At least 44 pixels high below md, where a finger taps it.
function DocumentLink({ document }: { document: VerificationDocument }) {
	return (
		<Link
			to="/documents/$documentId"
			params={{ documentId: document.id }}
			className="flex min-w-0 items-center gap-1 text-kumo-link underline underline-offset-2 max-md:min-h-11"
		>
			<span className="min-w-0 break-words">{documentLine(document)}</span>
			<CaretRightIcon size={14} className="shrink-0" aria-hidden />
		</Link>
	)
}

function EntryBadge({ item }: { item: VerificationItem }) {
	const { label, tone } = summarizeVerificationEntry(item).badge
	return <StatusBadge tone={tone}>{label}</StatusBadge>
}

function EntryCard({ heading, children, error }: { heading: ReactNode; children: ReactNode; error: Error | null }) {
	return (
		<LayerCard>
			<LayerCard.Secondary>
				<span className="flex min-w-0 flex-wrap items-center gap-2">{heading}</span>
			</LayerCard.Secondary>
			<LayerCard.Primary className="flex flex-col gap-4">
				{children}
				{error && <Text variant="error">{error.message}</Text>}
			</LayerCard.Primary>
		</LayerCard>
	)
}

function MergeConfirmation({
	item,
	target,
	label,
	variant,
	className,
}: {
	item: Extract<VerificationItem, { reason: "new_taxonomy_record" }>
	target: { id: string; name: string } | undefined
	label: string
	variant: "primary" | "secondary"
	className?: string
}) {
	const router = useRouter()
	const { record } = item
	const kindLabel = kindPresentations[record.kind].label
	const targetName = target?.name ?? ""
	return (
		<ActionConfirmation
			trigger={(open) => (
				<Button
					variant={variant}
					icon={GitMergeIcon}
					className={className}
					disabled={target === undefined}
					onClick={open}
				>
					{label}
				</Button>
			)}
			title={`Merge ${record.name} into ${targetName}?`}
			description={`${movedDocumentCount(item.documents.length)} from the ${kindLabel} ${record.name} to ${targetName}. Schublade then deletes ${record.name} and confirms ${targetName}. You cannot undo this.`}
			confirmationLabel="Merge"
			confirmationVariant="primary"
			action={() =>
				submitTaxonomyMerge({
					data: { kind: record.kind, sourceRecordId: record.id, targetRecordId: target?.id ?? "" },
				})
			}
			onCompleted={() => router.invalidate()}
		/>
	)
}

function NewRecordEntry({
	item,
	facets,
}: {
	item: Extract<VerificationItem, { reason: "new_taxonomy_record" }>
	facets: ArchiveFacets
}) {
	const { record } = item
	const { label, facet } = kindPresentations[record.kind]
	const reference = { kind: record.kind, recordId: record.id }
	const [renaming, setRenaming] = useState(false)
	const [name, setName] = useState(record.name)
	const mergeTargets = facets[facet].filter((option) => option.id !== record.id)
	const [targetRecordId, setTargetRecordId] = useState<string | null>(null)
	const router = useRouter()
	const confirmation = useVerificationAction(() => submitTaxonomyConfirmation({ data: reference }))
	const rename = useVerificationAction((renamed: string) =>
		submitTaxonomyRename({ data: { ...reference, name: renamed } }),
	)
	const proposedTarget = rename.data?.kind === "merge_proposed" ? rename.data.targetRecord : undefined
	return (
		<EntryCard
			heading={
				<>
					<EntryBadge item={item} />
					<span className="min-w-0 font-medium break-words">{record.name}</span>
				</>
			}
			error={confirmation.error ?? rename.error}
		>
			{item.documents.length === 0 ? (
				<Text variant="secondary">No document refers to this {label} any more.</Text>
			) : (
				<ul className="flex flex-col gap-1 text-sm text-kumo-subtle">
					{item.documents.map((document) => (
						<li key={document.id}>
							<DocumentLink document={document} />
						</li>
					))}
				</ul>
			)}
			{renaming && (
				<form
					className="flex flex-col gap-2 md:flex-row md:items-end"
					onSubmit={(event) => {
						event.preventDefault()
						if (name.trim() !== "") rename.mutate(name.trim())
					}}
				>
					<div className="w-full min-w-0 md:w-80">
						<Input
							label={`New ${label} name`}
							className="w-full min-w-0"
							value={name}
							onChange={(event) => setName(event.target.value)}
						/>
					</div>
					<Button type="submit" variant="primary" className={touchSized} loading={rename.isPending}>
						Save name
					</Button>
				</form>
			)}
			{proposedTarget && (
				<Banner
					variant="alert"
					title={`The ${label} ${proposedTarget.name} already has this name`}
					description={
						<MergeConfirmation
							item={item}
							target={proposedTarget}
							label={`Merge into ${proposedTarget.name}`}
							variant="primary"
							className={`${touchSized} mt-2`}
						/>
					}
				/>
			)}
			<div className="flex flex-col gap-2 md:flex-row md:flex-wrap md:items-end">
				<Button
					variant="primary"
					icon={CheckIcon}
					className={touchSized}
					loading={confirmation.isPending}
					onClick={() => confirmation.mutate()}
				>
					Confirm
				</Button>
				<Button
					variant="secondary"
					icon={PencilSimpleIcon}
					className={touchSized}
					aria-expanded={renaming}
					onClick={() => setRenaming(!renaming)}
				>
					Rename
				</Button>
				{mergeTargets.length > 0 && (
					<div className="flex flex-col gap-2 md:flex-row md:items-end">
						<Select<string>
							label={`Merge into ${label}`}
							className="w-full max-md:h-11 md:w-56"
							value={targetRecordId}
							placeholder={`Choose a ${label}`}
							onValueChange={setTargetRecordId}
							items={mergeTargets.map((option) => ({ value: option.id, label: option.name }))}
						/>
						<MergeConfirmation
							item={item}
							target={mergeTargets.find((option) => option.id === targetRecordId)}
							label="Merge"
							variant="secondary"
						/>
					</div>
				)}
				{item.documents.length === 0 && (
					<ActionConfirmation
						trigger={(open) => (
							<Button variant="secondary-destructive" icon={TrashIcon} className={touchSized} onClick={open}>
								Delete {label}
							</Button>
						)}
						title={`Delete the ${label} ${record.name}?`}
						description={`No document refers to ${record.name}, so Schublade deletes the ${label} and nothing else. You cannot undo this.`}
						confirmationLabel="Delete"
						confirmationVariant="destructive"
						action={() => submitTaxonomyDeletion({ data: reference })}
						onCompleted={() => router.invalidate()}
					/>
				)}
			</div>
		</EntryCard>
	)
}

function IllegibleFieldEntry({ item }: { item: Extract<VerificationItem, { reason: "illegible_required_field" }> }) {
	const [values, setValues] = useState<Partial<Record<RequiredFieldKey, string>>>(() =>
		Object.fromEntries(
			item.illegibleFields.map((field) => [field.fieldKey, field.value === null ? "" : String(field.value)]),
		),
	)
	const supply = useVerificationAction(() => {
		const amount = values.amount === undefined || values.amount === "" ? undefined : Number(values.amount)
		return submitDocumentRevision({
			data: {
				documentId: item.document.id,
				...(values.document_date !== undefined &&
					values.document_date !== "" && { documentDate: values.document_date }),
				...(amount !== undefined && { fields: { amount } }),
			},
		})
	})
	const complete = item.illegibleFields.every((field) => (values[field.fieldKey] ?? "") !== "")
	return (
		<EntryCard
			heading={
				<>
					<EntryBadge item={item} />
					<DocumentLink document={item.document} />
				</>
			}
			error={supply.error}
		>
			<form
				className="flex flex-col gap-3 md:flex-row md:items-end"
				onSubmit={(event) => {
					event.preventDefault()
					if (complete) supply.mutate(undefined)
				}}
			>
				{item.illegibleFields.map(({ fieldKey }) => (
					<div key={fieldKey} className="w-full min-w-0 md:w-56">
						<Input
							label={requiredFieldLabels[fieldKey]}
							className="w-full min-w-0"
							type={requiredFieldInputTypes[fieldKey]}
							inputMode={fieldKey === "amount" ? "decimal" : undefined}
							step={fieldKey === "amount" ? 0.01 : undefined}
							value={values[fieldKey] ?? ""}
							onChange={(event) => setValues({ ...values, [fieldKey]: event.target.value })}
						/>
					</div>
				))}
				<Button
					type="submit"
					variant="primary"
					icon={CheckIcon}
					className={touchSized}
					disabled={!complete}
					loading={supply.isPending}
				>
					Save
				</Button>
			</form>
		</EntryCard>
	)
}

function NonArchivalEntry({ item }: { item: Extract<VerificationItem, { reason: "non_archival_attachment" }> }) {
	const router = useRouter()
	const retention = useVerificationAction(() =>
		submitDocumentRevision({ data: { documentId: item.document.id, nonArchival: false } }),
	)
	return (
		<EntryCard
			heading={
				<>
					<EntryBadge item={item} />
					<DocumentLink document={item.document} />
				</>
			}
			error={retention.error}
		>
			<Text variant="secondary">
				The classifier read this file as boilerplate that came with another document, such as general terms.
			</Text>
			<div className="flex flex-col gap-2 md:flex-row">
				<ActionConfirmation
					trigger={(open) => (
						<Button variant="destructive" icon={TrashIcon} className={touchSized} onClick={open}>
							Delete attachment
						</Button>
					)}
					title="Delete this attachment?"
					description={documentDeletionDescription(item.document.title)}
					confirmationLabel="Delete"
					confirmationVariant="destructive"
					action={() => submitDocumentDeletion({ data: { documentId: item.document.id } })}
					onCompleted={() => router.invalidate()}
				/>
				<Button
					variant="secondary"
					className={touchSized}
					loading={retention.isPending}
					onClick={() => retention.mutate()}
				>
					Keep document
				</Button>
			</div>
		</EntryCard>
	)
}

function FailedIngestionEntry({ item }: { item: Extract<VerificationItem, { reason: "failed_ingestion" }> }) {
	return (
		<EntryCard
			heading={
				<>
					<EntryBadge item={item} />
					<DocumentLink document={item.document} />
				</>
			}
			error={null}
		>
			<Text variant="secondary">{documentFailureSentences[item.failureReason]}</Text>
			<FailedDocumentActions documentId={item.document.id} title={item.document.title} />
		</EntryCard>
	)
}

export function VerificationEntryControls({ item, facets }: { item: VerificationItem; facets: ArchiveFacets }) {
	switch (item.reason) {
		case "new_taxonomy_record":
			return <NewRecordEntry item={item} facets={facets} />
		case "illegible_required_field":
			return <IllegibleFieldEntry item={item} />
		case "non_archival_attachment":
			return <NonArchivalEntry item={item} />
		case "failed_ingestion":
			return <FailedIngestionEntry item={item} />
	}
}
