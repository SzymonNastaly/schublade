import { GitMergeIcon, PencilSimpleIcon, TrashIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { submitTaxonomyDeletion, submitTaxonomyMerge, submitTaxonomyRename } from "../utilities/server_functions"
import { ActionConfirmation } from "./action_confirmation"
import { taxonomyKindPresentations } from "./active_filter_presentation"
import { ActionButton } from "./controls/action_button"
import { FailureMessage, SelectionField, TextField } from "./controls/form_fields"
import { NoticeBox } from "./controls/notice_box"
import { PanelRowButton, SectionPanel } from "./controls/section_panel"
import type { FilteredTaxonomyRecord } from "./active_filter_presentation"
import type { SearchCriteria } from "../search/search_criteria"
import type { ComponentProps } from "react"

type CriteriaChange = (changes: Partial<SearchCriteria>) => void

/** States how many documents a merge moves, such as "3 documents move". */
function movedDocumentCount(count: number): string {
	if (count === 0) return "No document moves"
	return count === 1 ? "1 document moves" : `${count} documents move`
}

interface TaxonomyMergeConfirmationProperties {
	record: FilteredTaxonomyRecord
	target: { id: string; name: string } | undefined
	label: string
	variant: ComponentProps<typeof ActionButton>["variant"]
	onChange: CriteriaChange
}

/** The merge button and its confirmation. The source no longer exists afterwards, so the filter moves to the target. */
function TaxonomyMergeConfirmation({ record, target, label, variant, onChange }: TaxonomyMergeConfirmationProperties) {
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
					{label}
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

type OpenRecordForm = "rename" | "merge" | null

interface TaxonomyRecordPanelProperties {
	record: FilteredTaxonomyRecord
	onChange: CriteriaChange
}

/** Rename, merge, and delete of the sender, category, or tag the archive is filtered by. */
export function TaxonomyRecordPanel({ record, onChange }: TaxonomyRecordPanelProperties) {
	const router = useRouter()
	const { label, heading } = taxonomyKindPresentations[record.kind]
	const reference = { kind: record.kind, recordId: record.id }
	const [openForm, setOpenForm] = useState<OpenRecordForm>(null)
	const [name, setName] = useState(record.name)
	const [targetRecordId, setTargetRecordId] = useState("")
	const rename = useMutation({
		mutationFn: (renamed: string) => submitTaxonomyRename({ data: { ...reference, name: renamed } }),
		onSuccess: (outcome) => {
			if (outcome.kind !== "renamed") return
			setOpenForm(null)
			return router.invalidate()
		},
	})
	const proposedTarget = rename.data?.kind === "merge_proposed" ? rename.data.targetRecord : undefined
	const toggle = (form: Exclude<OpenRecordForm, null>) => setOpenForm(openForm === form ? null : form)
	return (
		<SectionPanel section="documents" heading={`${heading}: ${record.name}`}>
			<PanelRowButton section="documents" aria-expanded={openForm === "rename"} onClick={() => toggle("rename")}>
				<PencilSimpleIcon size={16} />
				Rename {label}
			</PanelRowButton>
			{openForm === "rename" && (
				<div className="flex flex-col gap-2 border-b border-documents-rule p-3 last:border-b-0">
					<form
						className="flex flex-col gap-2"
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
					{rename.error && <FailureMessage>{rename.error.message}</FailureMessage>}
					{proposedTarget && (
						<NoticeBox tone="documents" title={`The ${label} ${proposedTarget.name} already has this name`}>
							<div>
								<TaxonomyMergeConfirmation
									record={record}
									target={proposedTarget}
									label={`Merge into ${proposedTarget.name}`}
									variant="primary"
									onChange={onChange}
								/>
							</div>
						</NoticeBox>
					)}
				</div>
			)}
			{record.mergeTargets.length > 0 && (
				<PanelRowButton section="documents" aria-expanded={openForm === "merge"} onClick={() => toggle("merge")}>
					<GitMergeIcon size={16} />
					Merge into another {label}
				</PanelRowButton>
			)}
			{openForm === "merge" && (
				<div className="flex flex-col gap-2 border-b border-documents-rule p-3 last:border-b-0">
					<SelectionField
						label={`Merge into ${label}`}
						placeholder={`Choose a ${label}`}
						value={targetRecordId}
						onChange={(event) => setTargetRecordId(event.target.value)}
						options={record.mergeTargets.map((option) => ({ value: option.id, label: option.name }))}
					/>
					<div>
						<TaxonomyMergeConfirmation
							record={record}
							target={record.mergeTargets.find((option) => option.id === targetRecordId)}
							label="Merge"
							variant="secondary"
							onChange={onChange}
						/>
					</div>
				</div>
			)}
			{record.documentCount === 0 && (
				<ActionConfirmation
					trigger={(open) => (
						<PanelRowButton section="documents" destructive onClick={open}>
							<TrashIcon size={16} />
							Delete {label}
						</PanelRowButton>
					)}
					title={`Delete the ${label} ${record.name}?`}
					description={`No document in the archive refers to ${record.name}, so Schublade deletes the ${label} and nothing else. You cannot undo this.`}
					confirmationLabel="Delete"
					confirmationVariant="destructive"
					action={() => submitTaxonomyDeletion({ data: reference })}
					onCompleted={() => onChange({ [record.kind]: undefined })}
				/>
			)}
		</SectionPanel>
	)
}
