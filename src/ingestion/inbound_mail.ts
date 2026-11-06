import { inArray } from "drizzle-orm"
import PostalMime, { addressParser } from "postal-mime"
import { connectDatabase } from "../database/client"
import { documents } from "../database/schema"
import { MAXIMUM_FILES_PER_SUBMISSION, acceptDocumentUpload } from "./document_upload"
import { identifySourceFile } from "./source_file"
import type { MailContext } from "./classification_prompt"
import type { UploadEnvironment, UploadOutcome } from "./document_upload"
import type { Email, Header, PostalMimeOptions } from "postal-mime"

type MailEnvironment = UploadEnvironment & Pick<Env, "INGESTION_EMAIL_ADDRESS" | "MAIL_SENDER_ALLOWLIST">

type InboundMessage = Pick<ForwardableEmailMessage, "from" | "to" | "raw" | "rawSize" | "setReject">

// Mail clients embed signature logos and social icons as small inline images.
const INLINE_IMAGE_MINIMUM_BYTES = 15_000
// The body is classification context in the workflow payload, so it is cut to a bounded length.
const MAXIMUM_BODY_CHARACTERS = 4000
// Email Routing accepts messages up to 25 MiB, and the handler holds the message and its decoded
// attachments in a 128 MB isolate at once.
const MAXIMUM_MESSAGE_BYTES = 25 * 1024 * 1024
// Household mail nests a few levels and holds a few dozen parts. The postal-mime defaults of 256
// levels, 10,000 parts, 2 MiB of headers, and inline messages 10 deep admit far more, and every
// inline message/rfc822 level keeps its own copy of the nested message.
const PARSE_LIMITS = {
	maxNestingDepth: 32,
	maxPartCount: 1000,
	maxHeadersSize: 256 * 1024,
	maxRfc822NestingDepth: 2,
} satisfies PostalMimeOptions
const CLOUDFLARE_AUTHENTICATION_SERVICE = "mx.cloudflare.net"
const LOGGED_HEADER_COUNT = 12

const UNACCEPTED_RECIPIENT = "This address does not accept documents"
// Every sender check gives the same reason, so a forged sender cannot tell whether an envelope
// sender is on the allowlist.
const UNAUTHORIZED_SENDER = "This sender may not deliver documents to this archive"

function normalizeAddress(address: string): string {
	return address.trim().toLowerCase()
}

/**
 * Rejects a delivery on what Email Routing states about it, before any byte of the message is
 * read: the recipient, the size, and the envelope sender. A blank ingestion address accepts nothing.
 */
function rejectEnvelope(
	message: InboundMessage,
	environment: Pick<MailEnvironment, "INGESTION_EMAIL_ADDRESS" | "MAIL_SENDER_ALLOWLIST">,
): string | undefined {
	const ingestionAddress = normalizeAddress(environment.INGESTION_EMAIL_ADDRESS)
	if (ingestionAddress === "" || normalizeAddress(message.to) !== ingestionAddress) return UNACCEPTED_RECIPIENT
	if (message.rawSize > MAXIMUM_MESSAGE_BYTES) return "The message is larger than 25 MiB"
	const allowlist = environment.MAIL_SENDER_ALLOWLIST.map(normalizeAddress)
	if (!allowlist.includes(normalizeAddress(message.from))) return UNAUTHORIZED_SENDER
	return undefined
}

/** The semicolon-separated fields of an authentication results header, without comments. */
function resultFields(header: Header): Array<string> {
	return header.value
		.replace(/\([^)]*\)/g, "")
		.split(";")
		.map((field) => field.trim())
}

/**
 * The authserv-id of an Authentication-Results header, or of an ARC-Authentication-Results header
 * after its instance tag: the host that claims to have written the results.
 */
function authenticationService(header: Header): string {
	const fields = resultFields(header)
	const service = header.key === "arc-authentication-results" ? fields[1] : fields[0]
	return service?.split(/\s+/)[0]?.toLowerCase() ?? ""
}

/**
 * The dmarc result that Email Routing wrote, such as "dmarc=pass header.from=gmail.com".
 * Email Routing prepends a block of headers that opens with its own Received header and ends
 * before the Received header of the previous hop. Every relay prepends, so each header a sender
 * wrote sits below that second Received header, and only Cloudflare writes inside the block. The
 * result is read from the one mx.cloudflare.net Authentication-Results header inside the block.
 * Without a second Received header, the block cannot be told apart from the sender's headers.
 */
function cloudflareDmarcResult(headers: ReadonlyArray<Header>): string | undefined {
	if (headers[0]?.key !== "received") return undefined
	const blockEnd = headers.findIndex((header, index) => index > 0 && header.key === "received")
	if (blockEnd === -1) return undefined
	const cloudflareResults = headers
		.slice(0, blockEnd)
		.filter(
			(header) =>
				header.key === "authentication-results" && authenticationService(header) === CLOUDFLARE_AUTHENTICATION_SERVICE,
		)
	const [cloudflareResult] = cloudflareResults
	if (cloudflareResult === undefined || cloudflareResults.length > 1) return undefined
	return resultFields(cloudflareResult)
		.slice(1)
		.find((field) => /^dmarc\s*=/i.test(field))
}

/**
 * DMARC authenticates the domain of the From header, so the one From mailbox must be the envelope
 * sender, which the allowlist admitted, and Cloudflare's dmarc result must pass for its domain.
 */
function authenticatesSender(
	headers: ReadonlyArray<Header>,
	dmarcResult: string | undefined,
	envelopeSender: string,
): boolean {
	if (dmarcResult === undefined || !/^dmarc\s*=\s*pass\b/i.test(dmarcResult)) return false
	const fromHeaders = headers.filter((header) => header.key.trim() === "from")
	const fromMailboxes = fromHeaders.length === 1 ? addressParser(fromHeaders[0]?.value ?? "") : []
	const fromAddress = fromMailboxes.length === 1 ? fromMailboxes[0]?.address : undefined
	if (fromAddress === undefined || normalizeAddress(fromAddress) !== normalizeAddress(envelopeSender)) return false
	const evaluatedDomain = /\bheader\.from\s*=\s*([^\s;]+)/i.exec(dmarcResult)?.[1]
	return (
		evaluatedDomain === undefined || evaluatedDomain.toLowerCase() === normalizeAddress(fromAddress).split("@").pop()
	)
}

/**
 * The header layout of a delivery without addresses, subjects, or bodies: the names of its first
 * headers, the position and authserv-id of each authentication results header, the dmarc result
 * the handler trusted unless it names a mailbox, and whether the delivery was admitted.
 */
function describeHeaderLayout(headers: ReadonlyArray<Header>, dmarcResult: string | undefined, admitted: boolean) {
	return {
		firstHeaderNames: headers.slice(0, LOGGED_HEADER_COUNT).map((header) => header.originalKey),
		authenticationResults: headers.flatMap((header, index) =>
			header.key === "authentication-results" || header.key === "arc-authentication-results"
				? [{ index, header: header.originalKey, authenticationService: authenticationService(header) }]
				: [],
		),
		dmarcResult: dmarcResult?.includes("@") ? undefined : dmarcResult,
		admitted,
	}
}

/** The header section of a raw message, through the empty line that ends it. */
function headerSection(raw: Uint8Array<ArrayBuffer>): Uint8Array<ArrayBuffer> {
	for (let index = 0; index < raw.length - 1; index += 1) {
		if (raw[index] !== 0x0a) continue
		if (raw[index + 1] === 0x0a) return raw.subarray(0, index + 2)
		if (raw[index + 1] === 0x0d && raw[index + 2] === 0x0a) return raw.subarray(0, index + 3)
	}
	return raw
}

/** Parses under PARSE_LIMITS and returns undefined for a message beyond them. */
async function parseWithinLimits(content: Uint8Array<ArrayBuffer>): Promise<Email | undefined> {
	try {
		return await PostalMime.parse(content, PARSE_LIMITS)
	} catch (error) {
		if (error instanceof Error && "code" in error && String(error.code).startsWith("EMAX")) return undefined
		throw error
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
 * The email() handler: archives every PDF, JPEG, PNG, or WebP attachment of mail from an allowed,
 * DMARC authenticated sender with the subject, sender, and plain-text body as classification
 * context. Only the headers are parsed before the sender is authenticated. A retried delivery of
 * a message adds no document. Storage errors propagate, so Email Routing reports the delivery as
 * failed instead of the message disappearing.
 */
export async function receiveInboundMail(message: InboundMessage, environment: MailEnvironment): Promise<void> {
	const envelopeRejection = rejectEnvelope(message, environment)
	if (envelopeRejection !== undefined) {
		message.setReject(envelopeRejection)
		return
	}
	const raw = new Uint8Array(await new Response(message.raw).arrayBuffer())
	const headers = (await parseWithinLimits(headerSection(raw)))?.headers ?? []
	const dmarcResult = cloudflareDmarcResult(headers)
	const admitted = authenticatesSender(headers, dmarcResult, message.from)
	console.log("Inbound mail header layout", JSON.stringify(describeHeaderLayout(headers, dmarcResult, admitted)))
	if (!admitted) {
		message.setReject(UNAUTHORIZED_SENDER)
		return
	}
	const email = await parseWithinLimits(raw)
	if (email === undefined) {
		message.setReject("The message is nested too deeply or has too many parts")
		return
	}
	const messageIdentifier = email.messageId?.trim() ?? ""
	if (messageIdentifier === "") {
		message.setReject("The message has no Message-ID header")
		return
	}
	const senderAddress = normalizeAddress(message.from)

	const subject = email.subject?.trim() ?? ""
	const mailContext: MailContext = {
		senderAddress,
		subject,
		bodyText: (email.text ?? "").trim().slice(0, MAXIMUM_BODY_CHARACTERS),
	}
	const documentAttachments = email.attachments
		.map((attachment, index) => ({ attachment, index, content: attachmentBytes(attachment.content) }))
		.filter(({ attachment, content }) => !isSignatureGraphic(attachment.disposition, content))
	if (documentAttachments.length > MAXIMUM_FILES_PER_SUBMISSION) {
		message.setReject(
			`The message has more than ${MAXIMUM_FILES_PER_SUBMISSION} attachments. Send them in several messages.`,
		)
		return
	}
	const candidates = await Promise.all(
		documentAttachments
			// The content digest keeps a different message that reuses a Message-ID from being dropped.
			.map(async ({ attachment, index, content }) => ({
				documentId: await deriveDocumentIdentifier(
					messageIdentifier,
					`attachment ${index} ${await sha256Hexadecimal(content)}`,
				),
				file: new File([content], attachment.filename ?? `attachment-${index + 1}`),
			})),
	)
	const messageDocumentId = await deriveDocumentIdentifier(messageIdentifier, "message")
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
		`Inbound mail ${messageIdentifier} from ${senderAddress}`,
		JSON.stringify({ outcomes, awaitingRendering: awaitsRendering ? messageDocumentId : null }),
	)
}
