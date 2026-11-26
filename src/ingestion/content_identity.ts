import { isNull, sql } from "drizzle-orm"
import { contents } from "../database/schema"
import type { ArchiveDatabase } from "../database/client"

/** The SHA-256 of a byte sequence as lowercase hexadecimal, the name of a content throughout the archive. */
export async function sha256Hexadecimal(content: Uint8Array<ArrayBuffer>): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", content)
	return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
}

export type ContentState =
	| { sha256: string; state: "absent" }
	| { sha256: string; state: "present"; documentId: string }
	/** The archive received the content, and the document that held it was deleted since. */
	| { sha256: string; state: "deleted" }

/**
 * The state of each content, in the order asked. The digests bind as one JSON parameter, because
 * D1 allows 100 bound parameters per query.
 */
export async function lookupContents(
	database: ArchiveDatabase,
	digests: ReadonlyArray<string>,
): Promise<Array<ContentState>> {
	const rows = await database
		.select({ sha256: contents.sha256, documentId: contents.documentId })
		.from(contents)
		.where(sql`${contents.sha256} IN (SELECT value FROM json_each(${JSON.stringify(digests)}))`)
	const holders = new Map(rows.map((row) => [row.sha256, row.documentId]))
	return digests.map((sha256) => {
		const documentId = holders.get(sha256)
		if (documentId === undefined) return { sha256, state: "absent" }
		return documentId === null ? { sha256, state: "deleted" } : { sha256, state: "present", documentId }
	})
}

/**
 * Names the document that holds the content. A content that no document holds, because none
 * received it or because its document was deleted, takes this document. A content that a
 * document holds keeps that document, and the caller reads the row to learn which one won.
 */
export function claimContent(database: ArchiveDatabase, sha256: string, documentId: string) {
	return database
		.insert(contents)
		.values({ sha256, documentId })
		.onConflictDoUpdate({
			target: contents.sha256,
			set: { documentId: sql`excluded.document_id` },
			setWhere: isNull(contents.documentId),
		})
}
