import type { SearchIndex } from "./document_indexing"

interface StoredItem {
	content: string
	metadata: Record<string, unknown>
}

/** A SearchIndex for tests that keeps uploaded items in memory instead of calling the billed service. */
export function createInMemorySearchIndex() {
	const items = new Map<string, StoredItem>()
	const uploadedItemNames: Array<string> = []
	const searchIndex: SearchIndex = {
		search: () => Promise.reject(new Error("The in-memory index does not search")),
		items: {
			upload: (name, content, options) => {
				uploadedItemNames.push(name)
				items.set(name, { content: String(content), metadata: options?.metadata ?? {} })
				return Promise.resolve({ id: name, key: name, status: "completed" })
			},
			list: (parameters) => {
				const page = parameters?.page ?? 1
				const pageSize = parameters?.per_page ?? 50
				const listed = [...items.keys()]
					.filter((key) => parameters?.key === undefined || key === parameters.key)
					.map((key) => ({ id: key, key, status: "completed" as const }))
				return Promise.resolve({ result: listed.slice((page - 1) * pageSize, page * pageSize) })
			},
			delete: (itemId) => {
				items.delete(itemId)
				return Promise.resolve()
			},
		},
	}
	return { items, uploadedItemNames, searchIndex }
}
