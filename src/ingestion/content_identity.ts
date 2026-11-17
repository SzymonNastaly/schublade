import { and, asc, count, eq, inArray, isNull, sql } from "drizzle-orm"
import { connectDatabase } from "../database/client"
import { contents, documents } from "../database/schema"
import { acceptedMediaTypes } from "./source_file"
import type { ArchiveDatabase } from "../database/client"

const DIGEST_BATCH_SIZE = 25

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

export interface DigestReport {
	recordedDocumentIds: Array<string>
	/** Documents whose original R2 lacks. They are skipped and attempted again on the next run. */
	missingOriginalDocumentIds: Array<string>
	/** Documents still without a digest after this run, the skipped ones included. */
	remainingDocumentCount: number
}

/**
 * Records the digest of documents archived before digests existed, oldest first, and claims
 * each content for its document. Only an original of an accepted kind is digested: a stored
 * message awaits its rendering, after which the document shows the printed PDF. Recording the
 * digest is no revision of the document, so updated_at keeps its value and AI Search does not
 * upload the document again.
 */
export async function recordMissingContentDigests(database: ArchiveDatabase, storage: R2Bucket): Promise<DigestReport> {
	const undigested = and(isNull(documents.originalSha256), inArray(documents.mimeType, acceptedMediaTypes))
	const [pending, [remaining]] = await Promise.all([
		database
			.select({ id: documents.id, storageObjectKey: documents.storageObjectKey })
			.from(documents)
			.where(undigested)
			.orderBy(asc(documents.createdAt), asc(documents.id))
			.limit(DIGEST_BATCH_SIZE),
		database.select({ count: count() }).from(documents).where(undigested),
	])
	const recordedDocumentIds: Array<string> = []
	const missingOriginalDocumentIds: Array<string> = []
	for (const { id, storageObjectKey } of pending) {
		const original = await storage.get(storageObjectKey)
		if (!original) {
			console.warn(`Document ${id} has no original at ${storageObjectKey}, so its digest cannot be recorded`)
			missingOriginalDocumentIds.push(id)
			continue
		}
		const sha256 = await sha256Hexadecimal(new Uint8Array(await original.arrayBuffer()))
		await database.batch([
			database
				.update(documents)
				.set({ originalSha256: sha256, updatedAt: sql`${documents.updatedAt}` })
				.where(and(eq(documents.id, id), isNull(documents.originalSha256))),
			claimContent(database, sha256, id),
		])
		recordedDocumentIds.push(id)
	}
	return {
		recordedDocumentIds,
		missingOriginalDocumentIds,
		remainingDocumentCount: (remaining?.count ?? 0) - recordedDocumentIds.length,
	}
}

/** The scheduled run of the digest backfill, which logs one line per run. */
export async function recordMissingContentDigestsOnSchedule(
	environment: Pick<Env, "DATABASE" | "DOCUMENT_STORAGE">,
): Promise<void> {
	const report = await recordMissingContentDigests(connectDatabase(environment.DATABASE), environment.DOCUMENT_STORAGE)
	const missing = report.missingOriginalDocumentIds
	console.log(
		`Scheduled content digests: ${report.recordedDocumentIds.length} recorded, ${missing.length} without original, ` +
			`${report.remainingDocumentCount} remaining${missing.length > 0 ? `. Without original: ${missing.join(", ")}` : ""}`,
	)
}
