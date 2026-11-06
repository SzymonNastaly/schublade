import type { SearchIndex } from "./document_indexing"

interface StoredItem {
	content: string
	metadata: Record<string, unknown>
}

/** An upload that waits for the test, which decides when AI Search accepts it and when the call returns. */
interface HeldUpload {
	name: string
	content: string
	/** AI Search accepts the upload, so the item now holds its content. */
	accept: () => void
	/** The upload call returns to its caller. */
	release: () => void
}

/** A SearchIndex for tests that keeps uploaded items in memory instead of calling the billed service. */
export function createInMemorySearchIndex() {
	const items = new Map<string, StoredItem>()
	const uploadedItemNames: Array<string> = []
	let holdingUploads = false
	const heldUploads: Array<HeldUpload> = []
	const awaitingUploads: Array<(upload: HeldUpload) => void> = []
	const searchIndex: SearchIndex = {
		search: () => Promise.reject(new Error("The in-memory index does not search")),
		items: {
			upload: (name, content, options) => {
				uploadedItemNames.push(name)
				const store = () => items.set(name, { content: String(content), metadata: options?.metadata ?? {} })
				const info = { id: name, key: name, status: "completed" as const }
				if (!holdingUploads) {
					store()
					return Promise.resolve(info)
				}
				return new Promise((resolve) => {
					const held = { name, content: String(content), accept: store, release: () => resolve(info) }
					const awaiting = awaitingUploads.shift()
					if (awaiting) awaiting(held)
					else heldUploads.push(held)
				})
			},
			// The AI Search documentation names no exact key filter, so the listing ignores every filter.
			list: (parameters) => {
				const page = parameters?.page ?? 1
				const pageSize = parameters?.per_page ?? 20
				const listed = [...items.keys()].map((key) => ({ id: key, key, status: "completed" as const }))
				return Promise.resolve({ result: listed.slice((page - 1) * pageSize, page * pageSize) })
			},
			delete: (itemId) => {
				items.delete(itemId)
				return Promise.resolve()
			},
		},
	}
	return {
		items,
		uploadedItemNames,
		searchIndex,
		/** While held, each upload waits until the test accepts and releases it. */
		holdUploads: (holding: boolean) => {
			holdingUploads = holding
		},
		/** The next upload that waits, once a caller has started it. */
		nextHeldUpload: (): Promise<HeldUpload> => {
			const held = heldUploads.shift()
			return held ? Promise.resolve(held) : new Promise((resolve) => awaitingUploads.push(resolve))
		},
	}
}
