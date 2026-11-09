import { CheckIcon, GitMergeIcon, PencilSimpleIcon, TrashIcon } from "@phosphor-icons/react"
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
import { ActionConfirmation, documentDeletionDescription } from "./action_confirmation"
import { ActionButton } from "./controls/action_button"
import { FailureMessage, SelectionField, TextField } from "./controls/form_fields"
import { NoticeBox } from "./controls/notice_box"
import { SectionPanel } from "./controls/section_panel"
import { textLinkClasses } from "./controls/text_link"
import { formatDocumentDate } from "./document_formatting"
import { FailedDocumentActions } from "./upload_tray"
import { requiredFieldLabels } from "./verification_entries"
import type { ArchiveFacets } from "../archive/document_listing"
import type { TaxonomyKind } from "../archive/taxonomy_maintenance"
import type { VerificationDocument, VerificationItem } from "../archive/verification_items"
import type { RequiredFieldKey } from "../ingestion/verification_assessment"
import type { ComponentProps, ReactNode } from "react"

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

function AnswerPanel({ children, error }: { children: ReactNode; error: Error | null }) {
	return (
		<SectionPanel section="verification" heading="Your answer">
			<div className="flex flex-col gap-3 p-3.5">
				{children}
				{error && <FailureMessage>{error.message}</FailureMessage>}
			</div>
		</SectionPanel>
	)
}

function MergeConfirmation({
	item,
	target,
	label,
	variant,
}: {
	item: Extract<VerificationItem, { reason: "new_taxonomy_record" }>
	target: { id: string; name: string } | undefined
	label: string
	variant: ComponentProps<typeof ActionButton>["variant"]
}) {
	const router = useRouter()
	const { record } = item
	const kindLabel = kindPresentations[record.kind].label
	const targetName = target?.name ?? ""
	return (
		<ActionConfirmation
			trigger={(open) => (
				<ActionButton
					variant={variant}
					icon={GitMergeIcon}
					stretchOnPhone
					disabled={target === undefined}
					onClick={open}
				>
					{label}
				</ActionButton>
			)}
			section="verification"
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
	const [targetRecordId, setTargetRecordId] = useState("")
	const router = useRouter()
	const confirmation = useVerificationAction(() => submitTaxonomyConfirmation({ data: reference }))
	const rename = useVerificationAction((renamed: string) =>
		submitTaxonomyRename({ data: { ...reference, name: renamed } }),
	)
	const proposedTarget = rename.data?.kind === "merge_proposed" ? rename.data.targetRecord : undefined
	return (
		<AnswerPanel error={confirmation.error ?? rename.error}>
			<div className="flex flex-col gap-2 md:flex-row md:flex-wrap">
				<ActionButton
					variant="primary"
					icon={CheckIcon}
					stretchOnPhone
					pending={confirmation.isPending}
					onClick={() => confirmation.mutate()}
				>
					Confirm
				</ActionButton>
				<ActionButton
					variant="secondary"
					icon={PencilSimpleIcon}
					stretchOnPhone
					aria-expanded={renaming}
					onClick={() => setRenaming(!renaming)}
				>
					Rename
				</ActionButton>
			</div>
			{renaming && (
				<form
					className="flex flex-col gap-2 rounded-table border border-table-rule bg-table-label p-2.5"
					onSubmit={(event) => {
						event.preventDefault()
						if (name.trim() !== "") rename.mutate(name.trim())
					}}
				>
					<TextField label={`New ${label} name`} value={name} onChange={(event) => setName(event.target.value)} />
					<div>
						<ActionButton type="submit" variant="primary" stretchOnPhone pending={rename.isPending}>
							Save name
						</ActionButton>
					</div>
				</form>
			)}
			{proposedTarget && (
				<NoticeBox tone="verification" title={`The ${label} ${proposedTarget.name} already has this name`}>
					<div>
						<MergeConfirmation
							item={item}
							target={proposedTarget}
							label={`Merge into ${proposedTarget.name}`}
							variant="primary"
						/>
					</div>
				</NoticeBox>
			)}
			{mergeTargets.length > 0 && (
				<div className="flex flex-col gap-2 border-t border-dotted border-row-rule pt-3">
					<SelectionField
						label={`Or merge into ${label}`}
						placeholder={`Choose a ${label}`}
						value={targetRecordId}
						onChange={(event) => setTargetRecordId(event.target.value)}
						options={mergeTargets.map((option) => ({ value: option.id, label: option.name }))}
					/>
					<div>
						<MergeConfirmation
							item={item}
							target={mergeTargets.find((option) => option.id === targetRecordId)}
							label="Merge"
							variant="secondary"
						/>
					</div>
				</div>
			)}
			{item.documents.length === 0 && (
				<div>
					<ActionConfirmation
						trigger={(open) => (
							<ActionButton variant="secondaryDestructive" icon={TrashIcon} stretchOnPhone onClick={open}>
								Delete {label}
							</ActionButton>
						)}
						section="verification"
						title={`Delete the ${label} ${record.name}?`}
						description={`No document refers to ${record.name}, so Schublade deletes the ${label} and nothing else. You cannot undo this.`}
						confirmationLabel="Delete"
						confirmationVariant="destructive"
						action={() => submitTaxonomyDeletion({ data: reference })}
						onCompleted={() => router.invalidate()}
					/>
				</div>
			)}
			{item.documents.length > 1 && (
				<ul className="flex flex-col gap-1 border-t border-dotted border-row-rule pt-3 text-fine">
					{item.documents.map((document) => (
						<li key={document.id}>
							<Link to="/documents/$documentId" params={{ documentId: document.id }} className={textLinkClasses}>
								{documentLine(document)}
							</Link>
						</li>
					))}
				</ul>
			)}
		</AnswerPanel>
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
		<AnswerPanel error={supply.error}>
			<form
				className="flex flex-col gap-3"
				onSubmit={(event) => {
					event.preventDefault()
					if (complete) supply.mutate(undefined)
				}}
			>
				{item.illegibleFields.map(({ fieldKey }) => (
					<TextField
						key={fieldKey}
						label={requiredFieldLabels[fieldKey]}
						type={requiredFieldInputTypes[fieldKey]}
						inputMode={fieldKey === "amount" ? "decimal" : undefined}
						step={fieldKey === "amount" ? 0.01 : undefined}
						value={values[fieldKey] ?? ""}
						onChange={(event) => setValues({ ...values, [fieldKey]: event.target.value })}
					/>
				))}
				<div>
					<ActionButton
						type="submit"
						variant="primary"
						icon={CheckIcon}
						stretchOnPhone
						disabled={!complete}
						pending={supply.isPending}
					>
						Save
					</ActionButton>
				</div>
			</form>
		</AnswerPanel>
	)
}

function NonArchivalEntry({ item }: { item: Extract<VerificationItem, { reason: "non_archival_attachment" }> }) {
	const router = useRouter()
	const retention = useVerificationAction(() =>
		submitDocumentRevision({ data: { documentId: item.document.id, nonArchival: false } }),
	)
	return (
		<AnswerPanel error={retention.error}>
			<div className="flex flex-col gap-2 md:flex-row md:flex-wrap">
				<ActionButton
					variant="secondary"
					stretchOnPhone
					pending={retention.isPending}
					onClick={() => retention.mutate()}
				>
					Keep document
				</ActionButton>
				<ActionConfirmation
					trigger={(open) => (
						<ActionButton variant="destructive" icon={TrashIcon} stretchOnPhone onClick={open}>
							Delete attachment
						</ActionButton>
					)}
					section="verification"
					title="Delete this attachment?"
					description={documentDeletionDescription(item.document.title)}
					confirmationLabel="Delete"
					confirmationVariant="destructive"
					action={() => submitDocumentDeletion({ data: { documentId: item.document.id } })}
					onCompleted={() => router.invalidate()}
				/>
			</div>
		</AnswerPanel>
	)
}

function FailedIngestionEntry({ item }: { item: Extract<VerificationItem, { reason: "failed_ingestion" }> }) {
	return (
		<AnswerPanel error={null}>
			<FailedDocumentActions documentId={item.document.id} title={item.document.title} />
		</AnswerPanel>
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
