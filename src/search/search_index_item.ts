/**
 * The AI Search item of one archived document: its name, its text, and its custom metadata.
 * scripts/provision_environment.ts creates every instance with these metadata fields.
 */
export const searchIndexMetadataFields = [
	{ field_name: "person", data_type: "text" },
	{ field_name: "sender", data_type: "text" },
	{ field_name: "category", data_type: "text" },
	{ field_name: "document_date", data_type: "datetime" },
] as const

/** The person value of a document that concerns the whole household. */
const HOUSEHOLD_PERSON = "household"

// A type alias, unlike an interface, is assignable to the Record that the binding accepts.
export type SearchIndexMetadata = {
	person: string
	sender?: string
	category?: string
	document_date?: string
}

export interface IndexedDocument {
	id: string
	title: string | null
	/** ISO 8601 calendar date printed on the document. */
	documentDate: string | null
	senderId: string | null
	senderName: string | null
	categoryId: string | null
	/** Null assigns the document to the whole household. */
	personMemberId: string | null
	summary: string | null
	tagNames: Array<string>
	markdown: string
}

const itemNamePattern = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.md$/

export function searchIndexItemName(documentId: string): string {
	return `${documentId}.md`
}

/** The document identifier of an item name, or undefined for an item Schublade did not upload. */
export function documentIdOfItemName(itemName: string): string | undefined {
	return itemNamePattern.exec(itemName)?.[1]
}

/**
 * AI Search reads a datetime field from an ISO 8601 timestamp and compares range filters
 * against the same form, so a calendar date becomes midnight UTC of that day.
 */
function searchIndexDateTime(calendarDate: string): string {
	return `${calendarDate}T00:00:00Z`
}

export function searchIndexMetadata(document: IndexedDocument): SearchIndexMetadata {
	return {
		person: document.personMemberId ?? HOUSEHOLD_PERSON,
		...(document.senderId !== null && { sender: document.senderId }),
		...(document.categoryId !== null && { category: document.categoryId }),
		...(document.documentDate !== null && { document_date: searchIndexDateTime(document.documentDate) }),
	}
}

/** The title, sender, tags, and summary precede the full Markdown, so keyword and vector retrieval both see them. */
export function composeSearchIndexContent(document: IndexedDocument): string {
	const heading = [
		`# ${document.title ?? "Untitled document"}`,
		...(document.senderName === null ? [] : [`Sender: ${document.senderName}`]),
		...(document.tagNames.length === 0 ? [] : [`Tags: ${document.tagNames.join(", ")}`]),
	]
	return [heading.join("\n"), document.summary, document.markdown.trim()]
		.filter((section) => section !== null && section !== "")
		.join("\n\n")
		.concat("\n")
}
