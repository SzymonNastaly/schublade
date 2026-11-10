import { CheckIcon, TrashIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { useRouter } from "@tanstack/react-router"
import { useState } from "react"
import { submitDocumentDeletion, submitDocumentRevision } from "../utilities/server_functions"
import { ActionConfirmation, documentDeletionDescription } from "./action_confirmation"
import { ActionButton } from "./controls/action_button"
import { FailureMessage, TextField } from "./controls/form_fields"
import { SectionPanel } from "./controls/section_panel"
import { FailedDocumentActions } from "./upload_tray"
import { requiredFieldLabels } from "./verification_entries"
import type { VerificationItem } from "../archive/verification_items"
import type { RequiredFieldKey } from "../ingestion/verification_assessment"
import type { ReactNode } from "react"

const requiredFieldInputTypes: Record<RequiredFieldKey, "date" | "number"> = { document_date: "date", amount: "number" }

/** Runs an action, then reloads the entries and the navigation count, which drops the resolved entry. */
function useVerificationAction<TInput, TResult = unknown>(action: (input: TInput) => Promise<TResult>) {
	const router = useRouter()
	return useMutation({ mutationFn: action, onSuccess: () => router.invalidate() })
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

export function VerificationEntryControls({ item }: { item: VerificationItem }) {
	switch (item.reason) {
		case "illegible_required_field":
			return <IllegibleFieldEntry item={item} />
		case "non_archival_attachment":
			return <NonArchivalEntry item={item} />
		case "failed_ingestion":
			return <FailedIngestionEntry item={item} />
	}
}
