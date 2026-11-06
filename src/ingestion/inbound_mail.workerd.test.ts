import { applyD1Migrations, env, reset } from "cloudflare:test"
import { expect, inject, test, vi } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { receiveInboundMail } from "./inbound_mail"

const INGESTION_ADDRESS = "documents@archive.test"
const MEMBER_ADDRESS = "mira@example.com"
const PASSING_AUTHENTICATION = "mx.cloudflare.net; dkim=pass header.d=example.com; dmarc=pass header.from=example.com"

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

/** A synthetic RFC 5322 message, multipart/mixed with a text/plain body and the given parts. */
function composeMessage(message: {
	from: string
	messageId: string
	subject: string
	text: string
	authenticationResults: Array<string>
	parts: Array<MessagePart>
	received?: string
}): string {
	const boundary = "schublade-test-boundary"
	return [
		...message.authenticationResults.map((value) => `Authentication-Results: ${value}`),
		`Received: ${message.received ?? "from mail.example.com by mx.cloudflare.net; Fri, 06 Nov 2026 09:00:00 +0000"}`,
		`From: Mira Becker <${message.from}>`,
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
	authenticationResults: [PASSING_AUTHENTICATION],
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
		authenticationResults: [PASSING_AUTHENTICATION],
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

test("receiveInboundMail rejects mail whose From or DMARC result does not authenticate an allowed sender", async () => {
	const { environment } = await prepareArchive()
	const stranger = composeMessage({
		from: "stranger@example.org",
		messageId: "<offer-1@example.org>",
		subject: "Rechnung",
		text: "Bitte zahlen.",
		authenticationResults: ["mx.cloudflare.net; dmarc=pass header.from=example.org"],
		parts: [],
	})
	// Email Routing's own header comes first; the forged passing header below it is not trusted.
	const forged = composeMessage({
		from: MEMBER_ADDRESS,
		messageId: "<forged-1@example.net>",
		subject: "Rechnung",
		text: "Bitte zahlen.",
		authenticationResults: ["mx.cloudflare.net; spf=fail; dmarc=fail header.from=example.com", PASSING_AUTHENTICATION],
		parts: [],
	})

	expect({
		// DMARC passes for the From domain of the stranger, so the allowed envelope sender alone does not admit it.
		allowedEnvelopeOnly: await deliver(environment, stranger),
		forgedSender: await deliver(environment, forged),
		documents: await storedDocuments(),
		storedObjects: (await env.DOCUMENT_STORAGE.list()).objects,
	}).toEqual({
		allowedEnvelopeOnly: ["This sender may not deliver documents to this archive"],
		forgedSender: ["This sender may not deliver documents to this archive"],
		documents: [],
		storedObjects: [],
	})
})

test("receiveInboundMail trusts only Cloudflare's results as the first header, for a From that is the envelope sender", async () => {
	const { environment } = await prepareArchive()
	const household = { ...environment, MAIL_SENDER_ALLOWLIST: [MEMBER_ADDRESS, "jonas@example.com"] }
	const forgedBelowCloudflare = [
		"Authentication-Results: mx.cloudflare.net; dmarc=pass header.from=example.com",
		"Received: from mail.example.com by mx.cloudflare.net; Fri, 06 Nov 2026 09:00:00 +0000",
		"Authentication-Results: mx.cloudflare.net; dkim=pass header.d=example.com; dmarc=pass header.from=example.com",
		"From: Mira Becker <mira@example.com>",
		"To: documents@archive.test",
		"Subject: Rechnung",
		"Message-ID: <forged-below-1@example.com>",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"Bitte zahlen.",
		"",
	].join("\r\n")
	const forgedWithoutCloudflare = [
		"Received: from relay.example.net by mail.example.net; Fri, 06 Nov 2026 09:00:00 +0000",
		"Authentication-Results: mx.cloudflare.net; dmarc=pass header.from=example.com",
		"From: Mira Becker <mira@example.com>",
		"To: documents@archive.test",
		"Subject: Rechnung",
		"Message-ID: <forged-alone-1@example.com>",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"Bitte zahlen.",
		"",
	].join("\r\n")
	const missingFrom = [
		"Authentication-Results: mx.cloudflare.net; dmarc=pass header.from=example.com",
		"Received: from mail.example.com by mx.cloudflare.net; Fri, 06 Nov 2026 09:00:00 +0000",
		"To: documents@archive.test",
		"Subject: Rechnung",
		"Message-ID: <no-from-1@example.com>",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"Bitte zahlen.",
		"",
	].join("\r\n")
	const fromOtherMember = [
		"Authentication-Results: mx.cloudflare.net; dmarc=pass header.from=example.com",
		"Received: from mail.example.com by mx.cloudflare.net; Fri, 06 Nov 2026 09:00:00 +0000",
		"From: Jonas Becker <jonas@example.com>",
		"To: documents@archive.test",
		"Subject: Rechnung",
		"Message-ID: <other-member-1@example.com>",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"Bitte zahlen.",
		"",
	].join("\r\n")
	const repeatedFrom = [
		"Authentication-Results: mx.cloudflare.net; dmarc=pass header.from=example.com",
		"Received: from mail.example.com by mx.cloudflare.net; Fri, 06 Nov 2026 09:00:00 +0000",
		"From: Mira Becker <mira@example.com>",
		"From: Eve <eve@example.org>",
		"To: documents@archive.test",
		"Subject: Rechnung",
		"Message-ID: <repeated-from-1@example.com>",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"Bitte zahlen.",
		"",
	].join("\r\n")

	expect({
		forgedBelowCloudflare: await deliver(household, forgedBelowCloudflare),
		forgedWithoutCloudflare: await deliver(household, forgedWithoutCloudflare),
		missingFrom: await deliver(household, missingFrom),
		fromDiffersFromEnvelopeSender: await deliver(household, fromOtherMember),
		repeatedFrom: await deliver(household, repeatedFrom),
		documents: await storedDocuments(),
	}).toEqual({
		forgedBelowCloudflare: ["This sender may not deliver documents to this archive"],
		forgedWithoutCloudflare: ["This sender may not deliver documents to this archive"],
		missingFrom: ["This sender may not deliver documents to this archive"],
		fromDiffersFromEnvelopeSender: ["This sender may not deliver documents to this archive"],
		repeatedFrom: ["This sender may not deliver documents to this archive"],
		documents: [],
	})
})

test("receiveInboundMail archives a delivery that Cloudflare authenticated and logs its header layout", async () => {
	const { environment, workflowInstances } = await prepareArchive()
	const logged: Array<string> = []
	const log = vi.spyOn(console, "log").mockImplementation((...values: Array<unknown>) => logged.push(values.join(" ")))
	const delivery = [
		"Authentication-Results: mx.cloudflare.net; dkim=pass header.d=example.com header.s=mail; dmarc=pass header.from=example.com policy.dmarc=none; spf=pass (mx.cloudflare.net: domain of mira@example.com designates 192.0.2.25 as permitted sender) smtp.mailfrom=mira@example.com",
		"Received: from mail.example.com (mail.example.com [192.0.2.25]) by mx.cloudflare.net (Postfix) with ESMTPS id 4Xk2pQ for <documents@archive.test>; Fri, 06 Nov 2026 09:00:00 +0000",
		"ARC-Authentication-Results: i=1; mx.example.com; dkim=pass header.d=example.com",
		"DKIM-Signature: v=1; a=rsa-sha256; d=example.com; s=mail; h=from:to:subject; bh=aGVhZGVy; b=c2lnbmF0dXJl",
		"From: Mira Becker <mira@example.com>",
		"To: documents@archive.test",
		"Subject: Kassenbon Wochenmarkt",
		"Message-ID: <receipt-3318@example.com>",
		"Date: Fri, 06 Nov 2026 08:59:12 +0000",
		"X-Mailer: Apple Mail (2.3826.300.87)",
		"Content-Language: de-DE",
		"MIME-Version: 1.0",
		'Content-Type: multipart/mixed; boundary="receipt"',
		"",
		"--receipt",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"Kassenbon vom Wochenmarkt.",
		"--receipt",
		"Content-Type: image/jpeg",
		'Content-Disposition: attachment; filename="kassenbon.jpg"',
		"Content-Transfer-Encoding: base64",
		"",
		"/9j/4A==",
		"--receipt--",
		"",
	].join("\r\n")

	const rejections = await deliver(environment, delivery)
	log.mockRestore()

	const [document] = await storedDocuments()
	expect({
		rejections,
		documents: (await storedDocuments()).map(({ mimeType, status }) => ({ mimeType, status })),
		workflowInstances,
		headerLayout: logged.filter((line) => line.startsWith("Inbound mail header layout")),
	}).toEqual({
		rejections: [],
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
			'Inbound mail header layout {"firstHeaderNames":["Authentication-Results","Received","ARC-Authentication-Results","DKIM-Signature","From","To","Subject","Message-ID","Date","X-Mailer","Content-Language","MIME-Version"],"authenticationResults":[{"index":0,"header":"Authentication-Results","authenticationService":"mx.cloudflare.net"},{"index":2,"header":"ARC-Authentication-Results","authenticationService":"mx.example.com"}]}',
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
		authenticationResults: [PASSING_AUTHENTICATION],
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
		`Authentication-Results: ${PASSING_AUTHENTICATION}`,
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
	const retriedDelivery = forwardedInvoice.replace(
		"Received: from mail.example.com by mx.cloudflare.net; Fri, 06 Nov 2026 09:00:00 +0000",
		"Received: from mail.example.com by mx.cloudflare.net; Fri, 06 Nov 2026 09:05:00 +0000",
	)

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
