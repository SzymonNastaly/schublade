import { FloppyDiskIcon } from "@phosphor-icons/react"
import { useMutation } from "@tanstack/react-query"
import { useRouter } from "@tanstack/react-router"
import { useId, useState } from "react"
import { extractedFieldKeys, extractedFieldTypes } from "../ingestion/document_classification"
import { submitDocumentRevision } from "../utilities/server_functions"
import { ActionButton } from "./controls/action_button"
import { FailureMessage, SelectionField, TextField } from "./controls/form_fields"
import { TagField } from "./controls/tag_field"
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

interface DocumentRevisionFormProperties {
	document: ListedDocument
	facets: ArchiveFacets
	/** Runs after a saved revision has reloaded, and on Cancel. */
	onConcluded: () => void
}

/** The editable metadata and fields of a document. It starts from the stored values each time it mounts. */
export function DocumentRevisionForm({ document, facets, onConcluded }: DocumentRevisionFormProperties) {
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
			className="flex flex-col gap-3"
			onSubmit={(event) => {
				event.preventDefault()
				if (!unchanged) revision.mutate(values)
			}}
		>
			<TextField label="Title" value={values.title} onChange={(event) => change({ title: event.target.value })} />
			<TextField
				label="Document date"
				type="date"
				value={values.documentDate}
				onChange={(event) => change({ documentDate: event.target.value })}
			/>
			<TextField
				label="Sender"
				list={`${listIdentifier}-senders`}
				value={values.senderName}
				onChange={(event) => change({ senderName: event.target.value })}
			/>
			<TextField
				label="Category"
				list={`${listIdentifier}-categories`}
				value={values.categoryName}
				onChange={(event) => change({ categoryName: event.target.value })}
			/>
			{facets.members.length > 0 && (
				<SelectionField
					label="Person"
					value={values.person}
					onChange={(event) => change({ person: event.target.value })}
					options={[
						{ value: HOUSEHOLD_OPTION, label: "Household" },
						...facets.members.map((member) => ({ value: member.id, label: member.name })),
					]}
				/>
			)}
			<TagField label="Tags" limit={5} value={values.tagNames} onChange={(tagNames) => change({ tagNames })} />
			{offeredFieldKeys(values.categoryName, facets.categories, [initial.fields, values.fields]).map((fieldKey) => (
				<TextField
					key={fieldKey}
					label={fieldLabels[fieldKey]}
					type={{ number: "number", date: "date", text: "text" }[extractedFieldTypes[fieldKey]]}
					inputMode={extractedFieldTypes[fieldKey] === "number" ? "decimal" : undefined}
					step={extractedFieldTypes[fieldKey] === "number" ? 0.01 : undefined}
					value={values.fields[fieldKey]}
					onChange={(event) => changeField(fieldKey, event.target.value)}
				/>
			))}
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
			{revision.isError && <FailureMessage>{revision.error.message}</FailureMessage>}
			<div className="flex flex-col gap-2 md:flex-row">
				<ActionButton
					type="submit"
					variant="primary"
					icon={FloppyDiskIcon}
					stretchOnPhone
					disabled={unchanged}
					pending={revision.isPending}
				>
					Save changes
				</ActionButton>
				<ActionButton variant="secondary" stretchOnPhone onClick={onConcluded}>
					Cancel
				</ActionButton>
			</div>
		</form>
	)
}
