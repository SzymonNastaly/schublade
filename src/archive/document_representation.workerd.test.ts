import { applyD1Migrations, env } from "cloudflare:test"
import { expect, inject, test, vi } from "vitest"
import digitalStatement from "../../test_fixtures/documents/bank_statement_digital.pdf"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { serveDocumentRepresentation } from "./document_representation"

async function storeDocument(documentId: string, extension: string, mimeType: string, content: ArrayBuffer | string) {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const storageObjectKey = `documents/${documentId}/original.${extension}`
	await env.DOCUMENT_STORAGE.put(storageObjectKey, content, { httpMetadata: { contentType: mimeType } })
	await connectDatabase(env.DATABASE)
		.insert(documents)
		.values({ id: documentId, storageObjectKey, mimeType, byteSize: 1024, status: "archived" })
}

test("the thumbnail is the JPEG a client submitted, or a picture original itself, and a PDF without one has none and is not read", async () => {
	const submitted = "4a6c8e0b-2d1f-4c35-9b7e-6f1a3c5e7d92"
	const picture = "7c1f3a5b-9d2e-4f68-b0c4-3e8a6d1f9b72"
	const withoutThumbnail = "8d2a4b6c-0e3f-4a79-a1d5-4f9b7e2a0c83"
	await storeDocument(submitted, "pdf", "application/pdf", digitalStatement)
	await env.DOCUMENT_STORAGE.put(`documents/${submitted}/thumbnail.jpg`, "submitted thumbnail", {
		httpMetadata: { contentType: "image/jpeg" },
	})
	await storeDocument(picture, "png", "image/png", "photographed receipt")
	await storeDocument(withoutThumbnail, "pdf", "application/pdf", digitalStatement)
	const reads = vi.spyOn(env.DOCUMENT_STORAGE, "get")

	const answers = await Promise.all(
		[submitted, picture, withoutThumbnail].map(async (documentId) => {
			const response = await serveDocumentRepresentation(env, { documentId, representation: "thumbnail" })
			const body = new TextDecoder().decode(await response.arrayBuffer())
			return { status: response.status, type: response.headers.get("content-type"), body }
		}),
	)
	const readKeys = reads.mock.calls.map(([key]) => key)
	reads.mockRestore()

	expect({ answers, readsOfThePdf: readKeys.filter((key) => key.endsWith("/original.pdf")) }).toEqual({
		answers: [
			{ status: 200, type: "image/jpeg", body: "submitted thumbnail" },
			{ status: 200, type: "image/png", body: "photographed receipt" },
			{ status: 404, type: "text/plain;charset=UTF-8", body: "Not found" },
		],
		readsOfThePdf: [],
	})
})

test("an email not yet rendered has no thumbnail", async () => {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const documentId = "9e3b5c7d-1f4a-4b8a-92e6-5a0c8f3b1d94"
	const storageObjectKey = `documents/${documentId}/original.eml`
	await env.DOCUMENT_STORAGE.put(storageObjectKey, "Subject: Receipt")
	await connectDatabase(env.DATABASE).insert(documents).values({
		id: documentId,
		storageObjectKey,
		mimeType: "message/rfc822",
		byteSize: 16,
		status: "awaiting_rendering",
	})

	const response = await serveDocumentRepresentation(env, { documentId, representation: "thumbnail" })

	expect({ status: response.status, cached: response.headers.get("Cache-Control") }).toEqual({
		status: 404,
		cached: null,
	})
	await response.body?.cancel()
})

test("serveDocumentRepresentation forbids type sniffing and scripts on an original", async () => {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const documentId = "6b0e2f4a-8c1d-4e57-a9b3-2d7f5c0e8a61"
	const storageObjectKey = `documents/${documentId}/original.png`
	await env.DOCUMENT_STORAGE.put(storageObjectKey, "<script>alert(1)</script>", {
		httpMetadata: { contentType: "image/png" },
	})
	await connectDatabase(env.DATABASE)
		.insert(documents)
		.values({ id: documentId, storageObjectKey, mimeType: "image/png", byteSize: 25, status: "archived" })

	const response = await serveDocumentRepresentation(env, { documentId, representation: "original" })

	expect(Object.fromEntries(response.headers)).toEqual({
		"cache-control": "private, no-store",
		"content-disposition": "inline",
		"content-security-policy": "sandbox",
		"content-type": "image/png",
		"x-content-type-options": "nosniff",
	})
})
