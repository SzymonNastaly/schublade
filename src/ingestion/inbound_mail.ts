import { inArray } from "drizzle-orm"
import PostalMime from "postal-mime"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { acceptDocumentUpload } from "./document_upload"
import { identifySourceFile } from "./source_file"
import type { Caller } from "../authorization/caller_authorization"
import type { MailContext } from "./classification_prompt"
import type { UploadEnvironment, UploadOutcome } from "./document_upload"
import type { Email, Header } from "postal-mime"

type MailEnvironment = UploadEnvironment & Pick<Env, "INGESTION_EMAIL_ADDRESS" | "MAIL_SENDER_ALLOWLIST">

type InboundMessage = Pick<ForwardableEmailMessage, "from" | "to" | "raw" | "setReject">

// Mail clients embed signature logos and social icons as small inline images.
const INLINE_IMAGE_MINIMUM_BYTES = 15_000
// The body is classification context in the workflow payload, so it is cut to a bounded length.
const MAXIMUM_BODY_CHARACTERS = 4000
const CLOUDFLARE_AUTHENTICATION_SERVICE = "mx.cloudflare.net"

type MailAdmission =
	| { kind: "rejected"; reason: string }
	| { kind: "admitted"; caller: Extract<Caller, { kind: "inbound_mail" }>; messageIdentifier: string }

function normalizeAddress(address: string): string {
	return address.trim().toLowerCase()
}

/**
 * Email Routing prepends its own Authentication-Results header, so only the first one is
 * trusted; a sender can add others below it. DMARC authenticates the domain of the From header,
 * which is why the allowlist is checked against that address as well as the envelope sender.
 */
function passesDmarc(headers: ReadonlyArray<Header>, fromDomain: string): boolean {
	const authenticationResults = headers.find((header) => header.key === "authentication-results")
	if (authenticationResults === undefined) return false
	const [serviceIdentifier = "", ...results] = authenticationResults.value
		.replace(/\([^)]*\)/g, "")
		.split(";")
		.map((part) => part.trim())
	if (serviceIdentifier.split(/\s+/)[0]?.toLowerCase() !== CLOUDFLARE_AUTHENTICATION_SERVICE) return false
	const dmarcResult = results.find((result) => /^dmarc\s*=/i.test(result))
	if (dmarcResult === undefined || !/^dmarc\s*=\s*pass\b/i.test(dmarcResult)) return false
	const evaluatedDomain = /\bheader\.from\s*=\s*([^\s;]+)/i.exec(dmarcResult)?.[1]
	return evaluatedDomain === undefined || evaluatedDomain.toLowerCase() === fromDomain
}

/**
 * Admits a message only when it is addressed to the ingestion address and comes, DMARC
 * authenticated, from an address on the allowlist. A blank ingestion address admits nothing.
 * Authentication is checked before the allowlist, so a forged sender learns nothing about it.
 */
function admitMessage(
	envelope: { sender: string; recipient: string },
	email: Email,
	environment: Pick<MailEnvironment, "INGESTION_EMAIL_ADDRESS" | "MAIL_SENDER_ALLOWLIST">,
): MailAdmission {
	const ingestionAddress = normalizeAddress(environment.INGESTION_EMAIL_ADDRESS)
	if (ingestionAddress === "" || normalizeAddress(envelope.recipient) !== ingestionAddress) {
		return { kind: "rejected", reason: "This address does not accept documents" }
	}
	const fromAddress = normalizeAddress(email.from?.address ?? "")
	if (!passesDmarc(email.headers, fromAddress.split("@").pop() ?? "")) {
		return { kind: "rejected", reason: "The message failed DMARC sender authentication" }
	}
	const allowlist = new Set(environment.MAIL_SENDER_ALLOWLIST.map(normalizeAddress))
	if (!allowlist.has(fromAddress) || !allowlist.has(normalizeAddress(envelope.sender))) {
		return { kind: "rejected", reason: "This sender may not deliver documents to this archive" }
	}
	if (email.messageId === undefined || email.messageId.trim() === "") {
		return { kind: "rejected", reason: "The message has no Message-ID header" }
	}
	return {
		kind: "admitted",
		caller: { kind: "inbound_mail", senderAddress: fromAddress },
		messageIdentifier: email.messageId.trim(),
	}
}

async function sha256Hexadecimal(content: Uint8Array<ArrayBuffer>): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", content)
	return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
}

/**
 * A UUID version 8 derived from the Message-ID and the part of the message, so a retried
 * delivery of the same message addresses the documents its first delivery recorded.
 */
async function deriveDocumentIdentifier(messageIdentifier: string, part: string): Promise<string> {
	const bytes = new Uint8Array(
		await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${messageIdentifier}\n${part}`)),
	).slice(0, 16)
	bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x80
	bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80
	const hexadecimal = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")
	return [
		hexadecimal.slice(0, 8),
		hexadecimal.slice(8, 12),
		hexadecimal.slice(12, 16),
		hexadecimal.slice(16, 20),
		hexadecimal.slice(20),
	].join("-")
}

function attachmentBytes(content: ArrayBuffer | Uint8Array | string): Uint8Array<ArrayBuffer> {
	return typeof content === "string" ? new TextEncoder().encode(content) : new Uint8Array(content)
}

/** A signature graphic is an image that is not an explicit attachment and is smaller than 15 KB. */
function isSignatureGraphic(disposition: string | null, content: Uint8Array): boolean {
	return (
		disposition !== "attachment" &&
		identifySourceFile(content)?.kind === "image" &&
		content.byteLength < INLINE_IMAGE_MINIMUM_BYTES
	)
}

/**
 * Stores a message without a usable attachment as a document awaiting rendering, so phase 7 can
 * render its body into a PDF instead of the message being lost.
 */
async function storeMessageForRendering(
	environment: MailEnvironment,
	documentId: string,
	raw: Uint8Array<ArrayBuffer>,
	subject: string,
): Promise<void> {
	const storageObjectKey = `documents/${documentId}/original.eml`
	await environment.DOCUMENT_STORAGE.put(storageObjectKey, raw, { httpMetadata: { contentType: "message/rfc822" } })
	await connectDatabase(environment.DATABASE)
		.insert(documents)
		.values({
			id: documentId,
			title: subject === "" ? null : subject,
			storageObjectKey,
			mimeType: "message/rfc822",
			byteSize: raw.byteLength,
			status: "awaiting_rendering",
		})
		.onConflictDoNothing()
}

/**
 * The email() handler: archives every PDF, JPEG, PNG, or WebP attachment of an admitted message
 * with the subject, sender, and plain-text body as classification context. A retried delivery
 * of a message adds no document. Storage errors propagate, so Email Routing reports the delivery
 * as failed instead of the message disappearing.
 */
export async function receiveInboundMail(message: InboundMessage, environment: MailEnvironment): Promise<void> {
	const raw = new Uint8Array(await new Response(message.raw).arrayBuffer())
	const email = await PostalMime.parse(raw)
	const admission = admitMessage({ sender: message.from, recipient: message.to }, email, environment)
	if (admission.kind === "rejected") {
		message.setReject(admission.reason)
		return
	}

	const subject = email.subject?.trim() ?? ""
	const mailContext: MailContext = {
		senderAddress: admission.caller.senderAddress,
		subject,
		bodyText: (email.text ?? "").trim().slice(0, MAXIMUM_BODY_CHARACTERS),
	}
	const candidates = await Promise.all(
		email.attachments
			.map((attachment, index) => ({ attachment, index, content: attachmentBytes(attachment.content) }))
			.filter(({ attachment, content }) => !isSignatureGraphic(attachment.disposition, content))
			// The content digest keeps a different message that reuses a Message-ID from being dropped.
			.map(async ({ attachment, index, content }) => ({
				documentId: await deriveDocumentIdentifier(
					admission.messageIdentifier,
					`attachment ${index} ${await sha256Hexadecimal(content)}`,
				),
				file: new File([content], attachment.filename ?? `attachment-${index + 1}`),
			})),
	)
	const messageDocumentId = await deriveDocumentIdentifier(admission.messageIdentifier, "message")
	const database = connectDatabase(environment.DATABASE)
	const recordedIdentifiers = new Set(
		(
			await database
				.select({ id: documents.id })
				.from(documents)
				.where(inArray(documents.id, [messageDocumentId, ...candidates.map((candidate) => candidate.documentId)]))
		).map((document) => document.id),
	)

	const outcomes: Array<UploadOutcome> = []
	for (const { documentId, file } of candidates) {
		outcomes.push(
			recordedIdentifiers.has(documentId)
				? { kind: "accepted", fileName: file.name, documentId }
				: await acceptDocumentUpload(environment, file, { documentId, mailContext }),
		)
	}
	const awaitsRendering = outcomes.every((outcome) => outcome.kind === "rejected")
	if (awaitsRendering && !recordedIdentifiers.has(messageDocumentId)) {
		await storeMessageForRendering(environment, messageDocumentId, raw, subject)
	}
	console.log(
		`Inbound mail ${admission.messageIdentifier} from ${admission.caller.senderAddress}`,
		JSON.stringify({ outcomes, awaitingRendering: awaitsRendering ? messageDocumentId : null }),
	)
}
