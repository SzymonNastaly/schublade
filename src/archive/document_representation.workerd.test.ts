import { applyD1Migrations, env } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import digitalStatement from "../../test_fixtures/documents/bank_statement_digital.pdf"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { serveDocumentRepresentation } from "./document_representation"

async function storePdfDocument(documentId: string, content: ArrayBuffer | string) {
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const storageObjectKey = `documents/${documentId}/original.pdf`
	await env.DOCUMENT_STORAGE.put(storageObjectKey, content, { httpMetadata: { contentType: "application/pdf" } })
	await connectDatabase(env.DATABASE)
		.insert(documents)
		.values({ id: documentId, storageObjectKey, mimeType: "application/pdf", byteSize: 1024, status: "archived" })
}

test("the thumbnail of a PDF is rendered on first request and served from storage afterwards", async () => {
	const documentId = "7c1f3a5b-9d2e-4f68-b0c4-3e8a6d1f9b72"
	await storePdfDocument(documentId, digitalStatement)

	const rendered = await serveDocumentRepresentation(env, { documentId, representation: "thumbnail" })
	const pngSignature = [...new Uint8Array(await rendered.arrayBuffer()).slice(0, 4)]
	await env.DOCUMENT_STORAGE.put(`documents/${documentId}/thumbnail.png`, "stored thumbnail")
	const served = await serveDocumentRepresentation(env, { documentId, representation: "thumbnail" })

	expect({ status: rendered.status, type: rendered.headers.get("content-type"), pngSignature }).toEqual({
		status: 200,
		type: "image/png",
		pngSignature: [0x89, 0x50, 0x4e, 0x47],
	})
	expect(await served.text()).toBe("stored thumbnail")
})

test("a PDF that cannot be rendered has no thumbnail", async () => {
	const documentId = "8d2a4b6c-0e3f-4a79-c1d5-4f9b7e2a0c83"
	await storePdfDocument(documentId, "this is not a PDF")

	const response = await serveDocumentRepresentation(env, { documentId, representation: "thumbnail" })

	expect(response.status).toBe(404)
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
