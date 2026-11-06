import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test, vi } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { receiveInboundMail } from "./inbound_mail"

const INGESTION_ADDRESS = "documents@archive.test"
const MEMBER_ADDRESS = "mira@example.com"
const PASSING_AUTHENTICATION =
	"mx.cloudflare.net; dkim=pass header.d=example.com header.s=mail; dmarc=pass header.from=example.com policy.dmarc=none; spf=pass smtp.mailfrom=example.com"
const SENDER_RECEIVED =
	"Received: by 2002:a05:6000:1a8b:b0:3a4:f6b1:2c3d with SMTP id 4c8f2e1a; Fri, 06 Nov 2026 00:59:58 -0800 (PST)"

// A signature logo: PNG leading bytes padded to 1 KB.
const signatureImage = new Uint8Array(1024)
signatureImage.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

interface MessagePart {
	contentType: string
	disposition: "attachment" | "inline"
	fileName: string
	content: Uint8Array
}

function encodeBase64Lines(content: Uint8Array): string {
	let binary = ""
	for (let offset = 0; offset < content.length; offset += 8192) {
		binary += String.fromCharCode(...content.subarray(offset, offset + 8192))
	}
	return btoa(binary).replace(/.{76}/g, "$&\r\n")
}

/**
 * The headers Email Routing prepended to the first Gmail delivery on staging, from its Received
 * header to X-CF-SpamH-Score, with the given Authentication-Results values in their place.
 */
function emailRoutingBlock(cloudflareResults: Array<string>): Array<string> {
	return [
		"Received: from mail-wm1-f41.example.com (mail-wm1-f41.example.com [192.0.2.25]) by mx.cloudflare.net (Postfix) with ESMTPS id 4Xk2pQ for <documents@archive.test>; Fri, 06 Nov 2026 09:00:00 +0000",
		"ARC-Seal: i=1; a=rsa-sha256; s=2024; d=cloudflare.net; cv=none; b=c2VhbA==",
		"ARC-Message-Signature: i=1; a=rsa-sha256; c=relaxed/relaxed; d=cloudflare.net; s=2024; h=from:to:subject; bh=aGVhZGVy; b=c2lnbmF0dXJl",
		"ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com header.s=mail; dmarc=pass header.from=example.com policy.dmarc=none; spf=pass smtp.mailfrom=example.com",
		"Received-SPF: pass (mx.cloudflare.net: domain of example.com designates 192.0.2.25 as permitted sender) receiver=mx.cloudflare.net; client-ip=192.0.2.25",
		...cloudflareResults.map((value) => `Authentication-Results: ${value}`),
		"X-CF-SpamH-Score: 1",
	]
}

/**
 * A synthetic RFC 5322 message, multipart/mixed with a text/plain body and the given parts, in the
 * header layout of the first Gmail delivery on staging: Email Routing's block, then the headers of
 * the sender from its Received header through its From header.
 */
function composeMessage(message: {
	from: string
	messageId: string
	subject: string
	text: string
	parts: Array<MessagePart>
	cloudflareResults?: Array<string>
	senderHeaders?: Array<string>
}): string {
	const boundary = "schublade-test-boundary"
	return [
		...emailRoutingBlock(message.cloudflareResults ?? [PASSING_AUTHENTICATION]),
		...(message.senderHeaders ?? [
			SENDER_RECEIVED,
			"DKIM-Signature: v=1; a=rsa-sha256; d=example.com; s=mail; h=from:to:subject; bh=aGVhZGVy; b=c2lnbmF0dXJl",
			"X-Google-DKIM-Signature: v=1; a=rsa-sha256; d=1e100.net; s=20230601; h=from:to:subject; bh=aGVhZGVy; b=Z29vZ2xl",
			"X-Gm-Message-State: AOJu0YzK4Q2b",
			"X-Gm-Gg: ASbGncu7L1aT",
			`From: Mira Becker <${message.from}>`,
		]),
		`To: ${INGESTION_ADDRESS}`,
		`Subject: ${message.subject}`,
		`Message-ID: ${message.messageId}`,
		"Date: Fri, 06 Nov 2026 09:00:00 +0000",
		"MIME-Version: 1.0",
		`Content-Type: multipart/mixed; boundary="${boundary}"`,
		"",
		`--${boundary}`,
		"Content-Type: text/plain; charset=utf-8",
		"Content-Transfer-Encoding: 8bit",
		"",
		message.text,
		...message.parts.flatMap((part) => [
			`--${boundary}`,
			`Content-Type: ${part.contentType}; name="${part.fileName}"`,
			`Content-Disposition: ${part.disposition}; filename="${part.fileName}"`,
			"Content-Transfer-Encoding: base64",
			...(part.disposition === "inline" ? [`Content-ID: <${part.fileName}@example.com>`] : []),
			"",
			encodeBase64Lines(part.content),
		]),
		`--${boundary}--`,
		"",
	].join("\r\n")
}

const forwardedInvoice = composeMessage({
	from: MEMBER_ADDRESS,
	messageId: "<invoice-4471@example.com>",
	subject: "Fwd: Stromrechnung Oktober",
	text: "Anbei die Rechnung der Stadtwerke Talbrück.",
	parts: [
		{ contentType: "image/png", disposition: "inline", fileName: "logo.png", content: signatureImage },
		{
			contentType: "application/pdf",
			disposition: "attachment",
			fileName: "Rechnung.pdf",
			content: new Uint8Array(scannedInvoice),
		},
	],
})

const paymentRequest = {
	from: MEMBER_ADDRESS,
	messageId: "<payment-request-1@example.com>",
	subject: "Rechnung",
	text: "Bitte zahlen.",
	parts: [],
}

async function prepareArchive(ingestionAddress = INGESTION_ADDRESS) {
	await reset()
	await applyD1Migrations(env.DATABASE, inject("databaseMigrations"))
	const workflowInstances: Array<unknown> = []
	const workflow = {
		create: (options: unknown) => {
			workflowInstances.push(options)
			return Promise.resolve()
		},
	}
	return {
		workflowInstances,
		environment: {
			...env,
			INGESTION_EMAIL_ADDRESS: ingestionAddress,
			MAIL_SENDER_ALLOWLIST: ["Mira@Example.com"],
			DOCUMENT_INGESTION_WORKFLOW: workflow as unknown as Workflow,
		},
	}
}

/** Delivers a message as Email Routing would and returns the rejection reasons it set. */
async function deliver(
	environment: Awaited<ReturnType<typeof prepareArchive>>["environment"],
	raw: string,
	envelope: { from: string; to: string } = { from: MEMBER_ADDRESS, to: INGESTION_ADDRESS },
): Promise<Array<string>> {
	const rejections: Array<string> = []
	const content = new Blob([raw])
	await receiveInboundMail(
		{ ...envelope, raw: content.stream(), rawSize: content.size, setReject: (reason) => rejections.push(reason) },
		environment,
	)
	return rejections
}

async function storedDocuments() {
	return connectDatabase(env.DATABASE)
		.select({
			id: documents.id,
			title: documents.title,
			storageObjectKey: documents.storageObjectKey,
			mimeType: documents.mimeType,
			status: documents.status,
		})
		.from(documents)
}

test("receiveInboundMail archives the PDF of mail from an allowed sender and skips its signature image", async () => {
	const { environment, workflowInstances } = await prepareArchive()

	const rejections = await deliver(environment, forwardedInvoice)

	const [document] = await storedDocuments()
	expect({ rejections, documents: await storedDocuments(), workflowInstances }).toEqual({
		rejections: [],
		documents: [
			{
				id: document?.id,
				title: null,
				storageObjectKey: `documents/${document?.id}/original.pdf`,
				mimeType: "application/pdf",
				status: "processing",
			},
		],
		workflowInstances: [
			{
				id: document?.id,
				params: {
					documentId: document?.id,
					mailContext: {
						senderAddress: MEMBER_ADDRESS,
						subject: "Fwd: Stromrechnung Oktober",
						bodyText: "Anbei die Rechnung der Stadtwerke Talbrück.",
					},
				},
			},
		],
	})
})

test("receiveInboundMail stores mail without a usable attachment as awaiting rendering", async () => {
	const { environment, workflowInstances } = await prepareArchive()
	const receipt = composeMessage({
		from: MEMBER_ADDRESS,
		messageId: "<order-2219@example.com>",
		subject: "Fwd: Ihre Bestellung bei Paperlark",
		text: "Vielen Dank für Ihre Bestellung. Gesamtbetrag 12,99 EUR.",
		parts: [{ contentType: "image/png", disposition: "inline", fileName: "logo.png", content: signatureImage }],
	})

	const rejections = await deliver(environment, receipt)

	const [document] = await storedDocuments()
	const storedMessage = await env.DOCUMENT_STORAGE.get(`documents/${document?.id}/original.eml`)
	expect({
		rejections,
		documents: await storedDocuments(),
		storedMessage: await storedMessage?.text(),
		workflowInstances,
	}).toEqual({
		rejections: [],
		documents: [
			{
				id: document?.id,
				title: "Fwd: Ihre Bestellung bei Paperlark",
				storageObjectKey: `documents/${document?.id}/original.eml`,
				mimeType: "message/rfc822",
				status: "awaiting_rendering",
			},
		],
		storedMessage: receipt,
		workflowInstances: [],
	})
})

test("receiveInboundMail rejects a delivery by its envelope before reading the message", async () => {
	const { environment } = await prepareArchive()
	const unconfigured = (await prepareArchive("")).environment
	async function deliverUnreadable(
		deliveryEnvironment: typeof environment,
		envelope: { from: string; to: string; rawSize: number },
	): Promise<Array<string>> {
		const rejections: Array<string> = []
		const raw = new ReadableStream<Uint8Array>({
			pull: () => Promise.reject(new Error("The handler read the message")),
		})
		await receiveInboundMail({ ...envelope, raw, setReject: (reason) => rejections.push(reason) }, deliveryEnvironment)
		return rejections
	}

	expect({
		wrongRecipient: await deliverUnreadable(environment, {
			from: MEMBER_ADDRESS,
			to: "invoices@archive.test",
			rawSize: 2048,
		}),
		noIngestionAddress: await deliverUnreadable(unconfigured, {
			from: MEMBER_ADDRESS,
			to: INGESTION_ADDRESS,
			rawSize: 2048,
		}),
		oversized: await deliverUnreadable(environment, {
			from: MEMBER_ADDRESS,
			to: INGESTION_ADDRESS,
			rawSize: 26_214_401,
		}),
		unknownSender: await deliverUnreadable(environment, {
			from: "stranger@example.org",
			to: INGESTION_ADDRESS,
			rawSize: 2048,
		}),
	}).toEqual({
		wrongRecipient: ["This address does not accept documents"],
		noIngestionAddress: ["This address does not accept documents"],
		oversized: ["The message is larger than 25 MiB"],
		unknownSender: ["This sender may not deliver documents to this archive"],
	})
})

test("receiveInboundMail rejects mail whose From is not the one allowed envelope sender", async () => {
	const { environment } = await prepareArchive()
	const household = { ...environment, MAIL_SENDER_ALLOWLIST: [MEMBER_ADDRESS, "jonas@example.com"] }
	const memberFrom = `From: Mira Becker <${MEMBER_ADDRESS}>`
	const stranger = composeMessage({
		...paymentRequest,
		from: "stranger@example.org",
		cloudflareResults: ["mx.cloudflare.net; dmarc=pass header.from=example.org"],
	})

	expect({
		// DMARC passes for the From domain of the stranger, so the allowed envelope sender alone does not admit it.
		allowedEnvelopeOnly: await deliver(household, stranger),
		missingFrom: await deliver(household, composeMessage({ ...paymentRequest, senderHeaders: [SENDER_RECEIVED] })),
		fromDiffersFromEnvelopeSender: await deliver(
			household,
			composeMessage({ ...paymentRequest, from: "jonas@example.com" }),
		),
		repeatedFrom: await deliver(
			household,
			composeMessage({
				...paymentRequest,
				senderHeaders: [SENDER_RECEIVED, memberFrom, "From: Eve <eve@example.org>"],
			}),
		),
		documents: await storedDocuments(),
		storedObjects: (await env.DOCUMENT_STORAGE.list()).objects,
	}).toEqual({
		allowedEnvelopeOnly: ["This sender may not deliver documents to this archive"],
		missingFrom: ["This sender may not deliver documents to this archive"],
		fromDiffersFromEnvelopeSender: ["This sender may not deliver documents to this archive"],
		repeatedFrom: ["This sender may not deliver documents to this archive"],
		documents: [],
		storedObjects: [],
	})
})

test("receiveInboundMail trusts only the one mx.cloudflare.net result inside the block Email Routing prepends", async () => {
	const { environment } = await prepareArchive()
	const memberFrom = `From: Mira Becker <${MEMBER_ADDRESS}>`
	const passingResults = `Authentication-Results: ${PASSING_AUTHENTICATION}`

	expect({
		forgedBelowBlock: await deliver(
			environment,
			composeMessage({
				...paymentRequest,
				cloudflareResults: [],
				senderHeaders: [SENDER_RECEIVED, passingResults, memberFrom],
			}),
		),
		forgedPassBelowFailure: await deliver(
			environment,
			composeMessage({
				...paymentRequest,
				cloudflareResults: ["mx.cloudflare.net; spf=fail; dmarc=fail header.from=example.com"],
				senderHeaders: [SENDER_RECEIVED, passingResults, memberFrom],
			}),
		),
		twoInsideBlock: await deliver(
			environment,
			composeMessage({ ...paymentRequest, cloudflareResults: [PASSING_AUTHENTICATION, PASSING_AUTHENTICATION] }),
		),
		withoutSenderReceived: await deliver(
			environment,
			composeMessage({ ...paymentRequest, senderHeaders: [memberFrom] }),
		),
		resultsAboveReceived: await deliver(
			environment,
			`${passingResults}\r\n${composeMessage({ ...paymentRequest, cloudflareResults: [] })}`,
		),
		documents: await storedDocuments(),
	}).toEqual({
		forgedBelowBlock: ["This sender may not deliver documents to this archive"],
		forgedPassBelowFailure: ["This sender may not deliver documents to this archive"],
		twoInsideBlock: ["This sender may not deliver documents to this archive"],
		withoutSenderReceived: ["This sender may not deliver documents to this archive"],
		resultsAboveReceived: ["This sender may not deliver documents to this archive"],
		documents: [],
	})
})

test("receiveInboundMail archives a delivery in the layout Email Routing delivered on staging and logs each layout", async () => {
	const { environment, workflowInstances } = await prepareArchive()
	const logged: Array<string> = []
	const log = vi.spyOn(console, "log").mockImplementation((...values: Array<unknown>) => logged.push(values.join(" ")))
	const receipt = composeMessage({
		from: MEMBER_ADDRESS,
		messageId: "<receipt-3318@example.com>",
		subject: "Kassenbon Wochenmarkt",
		text: "Kassenbon vom Wochenmarkt.",
		parts: [
			{
				contentType: "image/jpeg",
				disposition: "attachment",
				fileName: "kassenbon.jpg",
				content: new Uint8Array([0xff, 0xd8, 0xff, 0xe0]),
			},
		],
	})
	// The dmarc result names a mailbox, so the log line leaves the result out.
	const failedDmarc = composeMessage({
		...paymentRequest,
		cloudflareResults: ["mx.cloudflare.net; dmarc=fail header.from=mira@example.com"],
	})

	const rejections = {
		receipt: await deliver(environment, receipt),
		failedDmarc: await deliver(environment, failedDmarc),
	}
	log.mockRestore()

	const [document] = await storedDocuments()
	expect({
		rejections,
		documents: (await storedDocuments()).map(({ mimeType, status }) => ({ mimeType, status })),
		workflowInstances,
		headerLayout: logged.filter((line) => line.startsWith("Inbound mail header layout")),
	}).toEqual({
		rejections: { receipt: [], failedDmarc: ["This sender may not deliver documents to this archive"] },
		documents: [{ mimeType: "image/jpeg", status: "processing" }],
		workflowInstances: [
			{
				id: document?.id,
				params: {
					documentId: document?.id,
					mailContext: {
						senderAddress: MEMBER_ADDRESS,
						subject: "Kassenbon Wochenmarkt",
						bodyText: "Kassenbon vom Wochenmarkt.",
					},
				},
			},
		],
		headerLayout: [
			'Inbound mail header layout {"firstHeaderNames":["Received","ARC-Seal","ARC-Message-Signature","ARC-Authentication-Results","Received-SPF","Authentication-Results","X-CF-SpamH-Score","Received","DKIM-Signature","X-Google-DKIM-Signature","X-Gm-Message-State","X-Gm-Gg"],"authenticationResults":[{"index":3,"header":"ARC-Authentication-Results","authenticationService":"mx.cloudflare.net"},{"index":5,"header":"Authentication-Results","authenticationService":"mx.cloudflare.net"}],"dmarcResult":"dmarc=pass header.from=example.com policy.dmarc=none","admitted":true}',
			'Inbound mail header layout {"firstHeaderNames":["Received","ARC-Seal","ARC-Message-Signature","ARC-Authentication-Results","Received-SPF","Authentication-Results","X-CF-SpamH-Score","Received","DKIM-Signature","X-Google-DKIM-Signature","X-Gm-Message-State","X-Gm-Gg"],"authenticationResults":[{"index":3,"header":"ARC-Authentication-Results","authenticationService":"mx.cloudflare.net"},{"index":5,"header":"Authentication-Results","authenticationService":"mx.cloudflare.net"}],"admitted":false}',
		],
	})
})

test("receiveInboundMail rejects mail from an allowed sender with more than 20 attachments", async () => {
	const { environment, workflowInstances } = await prepareArchive()
	const receipts = composeMessage({
		from: MEMBER_ADDRESS,
		messageId: "<receipts-21@example.com>",
		subject: "Kassenbons September",
		text: "Alle Kassenbons aus dem September.",
		parts: Array.from({ length: 21 }, (_, index) => ({
			contentType: "image/jpeg",
			disposition: "attachment" as const,
			fileName: `kassenbon-${index + 1}.jpg`,
			content: new Uint8Array([0xff, 0xd8, 0xff, 0xe0]),
		})),
	})

	expect({
		rejections: await deliver(environment, receipts),
		documents: await storedDocuments(),
		workflowInstances,
	}).toEqual({
		rejections: ["The message has more than 20 attachments. Send them in several messages."],
		documents: [],
		workflowInstances: [],
	})
})

test("receiveInboundMail rejects mail from an allowed sender whose parts nest beyond the parse limit", async () => {
	const { environment } = await prepareArchive()
	const levels = Array.from({ length: 40 }, (_, level) => level)
	const nested = [
		...emailRoutingBlock([PASSING_AUTHENTICATION]),
		SENDER_RECEIVED,
		`From: ${MEMBER_ADDRESS}`,
		`To: ${INGESTION_ADDRESS}`,
		"Subject: Verschachtelt",
		"Message-ID: <nested-1@example.com>",
		"MIME-Version: 1.0",
		'Content-Type: multipart/mixed; boundary="level-0"',
		"",
		...levels.flatMap((level) => [
			`--level-${level}`,
			`Content-Type: multipart/mixed; boundary="level-${level + 1}"`,
			"",
		]),
		...levels.toReversed().map((level) => `--level-${level}--`),
		"",
	].join("\r\n")

	expect({ rejections: await deliver(environment, nested), documents: await storedDocuments() }).toEqual({
		rejections: ["The message is nested too deeply or has too many parts"],
		documents: [],
	})
})

test("receiveInboundMail adds nothing when Email Routing delivers a message with the same Message-ID again", async () => {
	const { environment, workflowInstances } = await prepareArchive()
	const retriedDelivery = forwardedInvoice.replace("09:00:00 +0000", "09:05:00 +0000")

	await deliver(environment, forwardedInvoice)
	const [document] = await storedDocuments()
	const originalKey = `documents/${document?.id}/original.pdf`
	const firstVersion = (await env.DOCUMENT_STORAGE.head(originalKey))?.version
	await deliver(environment, retriedDelivery)

	expect({
		documentIdentifiers: (await storedDocuments()).map((stored) => stored.id),
		workflowInstanceIdentifiers: workflowInstances.map((instance) => (instance as { id: string }).id),
		originalRewritten: (await env.DOCUMENT_STORAGE.head(originalKey))?.version !== firstVersion,
	}).toEqual({
		documentIdentifiers: [document?.id],
		workflowInstanceIdentifiers: [document?.id],
		originalRewritten: false,
	})
})
