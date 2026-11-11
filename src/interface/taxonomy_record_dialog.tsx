import { GitMergeIcon, TrashIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { submitTaxonomyDeletion, submitTaxonomyMerge, submitTaxonomyRename } from "../utilities/server_functions"
import { ActionConfirmation } from "./action_confirmation"
import { taxonomyKindPresentations } from "./active_filter_presentation"
import { ActionButton } from "./controls/action_button"
import { FailureMessage, SelectionField, TextField } from "./controls/form_fields"
import { ModalDialog } from "./controls/modal_dialog"
import { NoticeBox } from "./controls/notice_box"
import type { FilteredTaxonomyRecord } from "./active_filter_presentation"
import type { SearchCriteria } from "../search/search_criteria"
import type { ComponentProps } from "react"

type CriteriaChange = (changes: Partial<SearchCriteria>) => void

/** States how many documents a merge moves, such as "3 documents move". */
function movedDocumentCount(count: number): string {
	if (count === 0) return "No document moves"
	return count === 1 ? "1 document moves" : `${count} documents move`
}

/** States how many archived documents refer to a record, such as "3 archived documents refer". */
function referringDocumentCount(count: number): string {
	if (count === 0) return "No archived document refers"
	return count === 1 ? "1 archived document refers" : `${count} archived documents refer`
}

interface TaxonomyMergeConfirmationProperties {
	record: FilteredTaxonomyRecord
	target: { id: string; name: string } | undefined
	variant: ComponentProps<typeof ActionButton>["variant"]
	onChange: CriteriaChange
}

/** The merge button and its confirmation. The source no longer exists afterwards, so the filter moves to the target. */
function TaxonomyMergeConfirmation({ record, target, variant, onChange }: TaxonomyMergeConfirmationProperties) {
	const kindLabel = taxonomyKindPresentations[record.kind].label
	const targetName = target?.name ?? ""
	const targetRecordId = target?.id ?? ""
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
					Merge
				</ActionButton>
			)}
			title={`Merge ${record.name} into ${targetName}?`}
			description={`${movedDocumentCount(record.documentCount)} from the ${kindLabel} ${record.name} to ${targetName}. Schublade then deletes ${record.name}. You cannot undo this.`}
			confirmationLabel="Merge"
			confirmationVariant="primary"
			action={() => submitTaxonomyMerge({ data: { kind: record.kind, sourceRecordId: record.id, targetRecordId } })}
			onCompleted={() => onChange({ [record.kind]: targetRecordId })}
		/>
	)
}

interface TaxonomyRecordDialogProperties {
	record: FilteredTaxonomyRecord
	onClose: () => void
	onChange: CriteriaChange
}

/** Rename, merge, and delete of the sender, category, or tag the archive is filtered by. */
export function TaxonomyRecordDialog({ record, onClose, onChange }: TaxonomyRecordDialogProperties) {
	const router = useRouter()
	const { label, heading } = taxonomyKindPresentations[record.kind]
	const reference = { kind: record.kind, recordId: record.id }
	const [name, setName] = useState(record.name)
	const [targetRecordId, setTargetRecordId] = useState("")
	const rename = useMutation({
		mutationFn: (renamed: string) => submitTaxonomyRename({ data: { ...reference, name: renamed } }),
		onSuccess: (outcome) => {
			if (outcome.kind === "renamed") return router.invalidate()
		},
	})
	const proposedTarget = rename.data?.kind === "merge_proposed" ? rename.data.targetRecord : undefined
	return (
		<ModalDialog
			open
			onOpenChange={(open) => {
				if (!open) onClose()
			}}
			section="documents"
			title={`${heading}: ${record.name}`}
			description={`${referringDocumentCount(record.documentCount)} to this ${label}.`}
		>
			<form
				className="flex flex-col gap-2"
				onSubmit={(event) => {
					event.preventDefault()
					if (name.trim() !== "") rename.mutate(name.trim())
				}}
			>
				<TextField label={`New ${label} name`} value={name} onChange={(event) => setName(event.target.value)} />
				<div>
					<ActionButton type="submit" variant="secondary" stretchOnPhone pending={rename.isPending}>
						Rename
					</ActionButton>
				</div>
			</form>
			{rename.error && <FailureMessage>{rename.error.message}</FailureMessage>}
			{proposedTarget && (
				<NoticeBox tone="documents" title={`The ${label} ${proposedTarget.name} already has this name`}>
					<div>
						<TaxonomyMergeConfirmation record={record} target={proposedTarget} variant="primary" onChange={onChange} />
					</div>
				</NoticeBox>
			)}
			{record.mergeTargets.length > 0 && (
				<div className="flex flex-col gap-2 border-t border-documents-rule pt-3">
					<SelectionField
						label={`Merge into another ${label}`}
						placeholder={`Choose a ${label}`}
						value={targetRecordId}
						onChange={(event) => setTargetRecordId(event.target.value)}
						options={record.mergeTargets.map((option) => ({ value: option.id, label: option.name }))}
					/>
					<div>
						<TaxonomyMergeConfirmation
							record={record}
							target={record.mergeTargets.find((option) => option.id === targetRecordId)}
							variant="secondary"
							onChange={onChange}
						/>
					</div>
				</div>
			)}
			<div className="flex flex-col-reverse gap-2 border-t border-documents-rule pt-3 md:flex-row md:justify-end">
				{record.documentCount === 0 && (
					<div className="md:mr-auto">
						<ActionConfirmation
							trigger={(open) => (
								<ActionButton variant="secondaryDestructive" icon={TrashIcon} stretchOnPhone onClick={open}>
									Delete {label}
								</ActionButton>
							)}
							title={`Delete the ${label} ${record.name}?`}
							description={`No document in the archive refers to ${record.name}, so Schublade deletes the ${label} and nothing else. You cannot undo this.`}
							confirmationLabel="Delete"
							confirmationVariant="destructive"
							action={() => submitTaxonomyDeletion({ data: reference })}
							onCompleted={() => onChange({ [record.kind]: undefined })}
						/>
					</div>
				)}
				<ActionButton variant="secondary" stretchOnPhone onClick={onClose}>
					Close
				</ActionButton>
			</div>
		</ModalDialog>
	)
}
