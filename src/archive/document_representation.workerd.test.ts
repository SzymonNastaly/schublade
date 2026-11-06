import { applyD1Migrations, env } from "cloudflare:test"
import { expect, inject, test } from "vitest"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { serveDocumentRepresentation } from "./document_representation"

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
