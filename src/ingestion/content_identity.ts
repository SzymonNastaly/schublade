import { and, asc, count, eq, gt, inArray, isNull, or, sql } from "drizzle-orm"
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
	/** Documents whose digest could not be recorded, such as one deleted during the run. */
	failedDocumentIds: Array<string>
	/** Documents still without a digest after this run, the skipped and failed ones included. */
	remainingDocumentCount: number
}

const undigestedDocuments = and(isNull(documents.originalSha256), inArray(documents.mimeType, acceptedMediaTypes))

async function recordContentDigest(
	database: ArchiveDatabase,
	storage: R2Bucket,
	{ id, storageObjectKey }: { id: string; storageObjectKey: string },
): Promise<"recorded" | "missing_original"> {
	const original = await storage.get(storageObjectKey)
	if (!original) return "missing_original"
	const sha256 = await sha256Hexadecimal(new Uint8Array(await original.arrayBuffer()))
	await database.batch([
		database
			.update(documents)
			.set({ originalSha256: sha256, updatedAt: sql`${documents.updatedAt}` })
			.where(and(eq(documents.id, id), isNull(documents.originalSha256))),
		claimContent(database, sha256, id),
	])
	return "recorded"
}

/**
 * Records the digest of up to 25 documents archived before digests existed, oldest first, and
 * claims each content for its document. Documents it cannot digest are passed over, so they never
 * hold back the ones after them. Only an original of an accepted kind is digested: a stored
 * message awaits its rendering, after which the document shows the printed PDF. Recording the
 * digest is no revision of the document, so updated_at keeps its value and AI Search does not
 * upload the document again.
 */
export async function recordMissingContentDigests(database: ArchiveDatabase, storage: R2Bucket): Promise<DigestReport> {
	const report: DigestReport = {
		recordedDocumentIds: [],
		missingOriginalDocumentIds: [],
		failedDocumentIds: [],
		remainingDocumentCount: 0,
	}
	let pageEnd: { id: string; createdAt: Date } | undefined
	while (report.recordedDocumentIds.length < DIGEST_BATCH_SIZE) {
		const page = await database
			.select({ id: documents.id, storageObjectKey: documents.storageObjectKey, createdAt: documents.createdAt })
			.from(documents)
			.where(
				pageEnd === undefined
					? undigestedDocuments
					: and(
							undigestedDocuments,
							or(
								gt(documents.createdAt, pageEnd.createdAt),
								and(eq(documents.createdAt, pageEnd.createdAt), gt(documents.id, pageEnd.id)),
							),
						),
			)
			.orderBy(asc(documents.createdAt), asc(documents.id))
			.limit(DIGEST_BATCH_SIZE)
		for (const document of page.slice(0, DIGEST_BATCH_SIZE - report.recordedDocumentIds.length)) {
			try {
				const outcome = await recordContentDigest(database, storage, document)
				if (outcome === "recorded") report.recordedDocumentIds.push(document.id)
				else {
					console.warn(
						`Document ${document.id} has no original at ${document.storageObjectKey}, so its digest cannot be recorded`,
					)
					report.missingOriginalDocumentIds.push(document.id)
				}
			} catch (error) {
				console.error(`Recording the digest of document ${document.id} failed`, error)
				report.failedDocumentIds.push(document.id)
			}
		}
		pageEnd = page.at(-1)
		if (page.length < DIGEST_BATCH_SIZE) break
	}
	const [remaining] = await database.select({ count: count() }).from(documents).where(undigestedDocuments)
	report.remainingDocumentCount = remaining?.count ?? 0
	return report
}

/** The scheduled run of the digest backfill, which logs one line per run. */
export async function recordMissingContentDigestsOnSchedule(
	environment: Pick<Env, "DATABASE" | "DOCUMENT_STORAGE">,
): Promise<void> {
	const report = await recordMissingContentDigests(connectDatabase(environment.DATABASE), environment.DOCUMENT_STORAGE)
	const missing = report.missingOriginalDocumentIds
	const failed = report.failedDocumentIds
	console.log(
		`Scheduled content digests: ${report.recordedDocumentIds.length} recorded, ${missing.length} without original, ` +
			`${failed.length} failed, ${report.remainingDocumentCount} remaining` +
			`${missing.length > 0 ? `. Without original: ${missing.join(", ")}` : ""}`,
	)
}
