import { Button, Input, Select, TagInput, Text } from "@cloudflare/kumo"
import { FloppyDiskIcon, TrashIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { useRouter } from "@tanstack/react-router"
import { useId, useState } from "react"
import { extractedFieldKeys, extractedFieldTypes } from "../ingestion/document_classification"
import { submitDocumentDeletion, submitDocumentRevision } from "../utilities/server_functions"
import { ActionConfirmation, documentDeletionDescription } from "./action_confirmation"
import { fieldLabels, offeredFieldKeys } from "./document_detail_presentation"
import type { ArchiveFacets, ListedDocument } from "../archive/document_listing"
import type { ExtractedFieldKey } from "../ingestion/document_classification"

const HOUSEHOLD_OPTION = "household"

interface RevisionValues {
	title: string
	documentDate: string
	senderName: string
	categoryName: string
	person: string
	tagNames: Array<string>
	fields: Record<ExtractedFieldKey, string>
}

function initialValues(document: ListedDocument): RevisionValues {
	const field = (fieldKey: ExtractedFieldKey) => {
		const value = document.fields.find((candidate) => candidate.fieldKey === fieldKey)?.value
		return value === null || value === undefined ? "" : String(value)
	}
	return {
		title: document.title ?? "",
		documentDate: document.documentDate ?? "",
		senderName: document.senderName ?? "",
		categoryName: document.categoryName ?? "",
		person: document.personMemberId ?? HOUSEHOLD_OPTION,
		tagNames: document.tagNames,
		fields: Object.fromEntries(extractedFieldKeys.map((fieldKey) => [fieldKey, field(fieldKey)])) as Record<
			ExtractedFieldKey,
			string
		>,
	}
}

const blankToNull = (text: string) => (text.trim() === "" ? null : text.trim())

/** Only the attributes the member changed, so the classifier's confidence stays on the others. */
function revisionOf(documentId: string, initial: RevisionValues, values: RevisionValues) {
	const changedFields = extractedFieldKeys.filter((fieldKey) => values.fields[fieldKey] !== initial.fields[fieldKey])
	return {
		documentId,
		...(values.title !== initial.title && { title: blankToNull(values.title) }),
		...(values.documentDate !== initial.documentDate && { documentDate: blankToNull(values.documentDate) }),
		...(values.senderName !== initial.senderName && { senderName: blankToNull(values.senderName) }),
		...(values.categoryName !== initial.categoryName && { categoryName: blankToNull(values.categoryName) }),
		...(values.person !== initial.person && {
			personMemberId: values.person === HOUSEHOLD_OPTION ? null : values.person,
		}),
		...(values.tagNames.join("\n") !== initial.tagNames.join("\n") && { tagNames: values.tagNames }),
		...(changedFields.length > 0 && {
			fields: Object.fromEntries(
				changedFields.map((fieldKey) => {
					const text = blankToNull(values.fields[fieldKey])
					return [fieldKey, text === null || extractedFieldTypes[fieldKey] !== "number" ? text : Number(text)]
				}),
			),
		}),
	}
}

function DocumentDeletion({ document, onDeleted }: { document: ListedDocument; onDeleted: () => void }) {
	const router = useRouter()
	return (
		<ActionConfirmation
			label="Delete document"
			icon={TrashIcon}
			variant="secondary-destructive"
			title="Delete this document?"
			description={documentDeletionDescription(document.title)}
			confirmationLabel="Delete"
			confirmationVariant="destructive"
			action={() => submitDocumentDeletion({ data: { documentId: document.id } })}
			onCompleted={() => {
				onDeleted()
				return router.invalidate()
			}}
		/>
	)
}

interface DocumentRevisionFormProperties {
	document: ListedDocument
	facets: ArchiveFacets
	onDeleted: () => void
	/** Runs after a saved revision has reloaded, and on Cancel. */
	onConcluded: () => void
}

/** The editable metadata and fields of a document. It starts from the stored values each time it mounts. */
export function DocumentRevisionForm({ document, facets, onDeleted, onConcluded }: DocumentRevisionFormProperties) {
	const router = useRouter()
	const listIdentifier = useId()
	const [initial] = useState(() => initialValues(document))
	const [values, setValues] = useState(initial)
	const revision = useMutation({
		mutationFn: (revised: RevisionValues) =>
			submitDocumentRevision({ data: revisionOf(document.id, initial, revised) }),
		onSuccess: async () => {
			await router.invalidate()
			onConcluded()
		},
	})
	const change = (changes: Partial<RevisionValues>) => setValues({ ...values, ...changes })
	const changeField = (fieldKey: ExtractedFieldKey, text: string) =>
		setValues({ ...values, fields: { ...values.fields, [fieldKey]: text } })
	const unchanged = Object.keys(revisionOf(document.id, initial, values)).length === 1
	return (
		<form
			className="flex flex-col gap-4"
			onSubmit={(event) => {
				event.preventDefault()
				if (!unchanged) revision.mutate(values)
			}}
		>
			<div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
				<Input
					label="Title"
					className="w-full min-w-0 max-md:h-11"
					value={values.title}
					onChange={(event) => change({ title: event.target.value })}
				/>
				<Input
					label="Document date"
					type="date"
					className="w-full min-w-0 max-md:h-11"
					value={values.documentDate}
					onChange={(event) => change({ documentDate: event.target.value })}
				/>
				<Input
					label="Sender"
					className="w-full min-w-0 max-md:h-11"
					list={`${listIdentifier}-senders`}
					value={values.senderName}
					onChange={(event) => change({ senderName: event.target.value })}
				/>
				<Input
					label="Category"
					className="w-full min-w-0 max-md:h-11"
					list={`${listIdentifier}-categories`}
					value={values.categoryName}
					onChange={(event) => change({ categoryName: event.target.value })}
				/>
				{facets.members.length > 0 && (
					<Select<string>
						label="Person"
						className="w-full max-md:h-11"
						value={values.person}
						onValueChange={(person) => change({ person: person ?? HOUSEHOLD_OPTION })}
						items={[
							{ value: HOUSEHOLD_OPTION, label: "Household" },
							...facets.members.map((member) => ({ value: member.id, label: member.name })),
						]}
					/>
				)}
				<TagInput
					label="Tags"
					className="w-full min-w-0 max-md:min-h-11"
					maxValues={5}
					value={values.tagNames}
					onValueChange={(tagNames) => change({ tagNames })}
				/>
				{offeredFieldKeys(values.categoryName, facets.categories, [initial.fields, values.fields]).map((fieldKey) => (
					<Input
						key={fieldKey}
						label={fieldLabels[fieldKey]}
						className="w-full min-w-0 max-md:h-11"
						type={{ number: "number", date: "date", text: "text" }[extractedFieldTypes[fieldKey]]}
						inputMode={extractedFieldTypes[fieldKey] === "number" ? "decimal" : undefined}
						step={extractedFieldTypes[fieldKey] === "number" ? 0.01 : undefined}
						value={values.fields[fieldKey]}
						onChange={(event) => changeField(fieldKey, event.target.value)}
					/>
				))}
			</div>
			<datalist id={`${listIdentifier}-senders`}>
				{facets.senders.map((sender) => (
					<option key={sender.id} value={sender.name} />
				))}
			</datalist>
			<datalist id={`${listIdentifier}-categories`}>
				{facets.categories.map((category) => (
					<option key={category.id} value={category.name} />
				))}
			</datalist>
			{revision.isError && <Text variant="error">{revision.error.message}</Text>}
			<div className="flex flex-col gap-2 md:flex-row md:flex-wrap md:justify-between">
				<div className="flex flex-col gap-2 md:flex-row">
					<Button
						type="submit"
						variant="primary"
						icon={FloppyDiskIcon}
						className="w-full max-md:h-11 md:w-auto"
						disabled={unchanged}
						loading={revision.isPending}
					>
						Save changes
					</Button>
					<Button variant="secondary" className="w-full max-md:h-11 md:w-auto" onClick={onConcluded}>
						Cancel
					</Button>
				</div>
				<DocumentDeletion document={document} onDeleted={onDeleted} />
			</div>
		</form>
	)
}
