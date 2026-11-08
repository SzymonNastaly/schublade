import PostalMime from "postal-mime"
import type { Attachment, Email, PostalMimeOptions } from "postal-mime"
import type { MailContext } from "./classification_prompt"

// Household mail nests a few levels and holds a few dozen parts. The postal-mime defaults of 256
// levels, 10,000 parts, 2 MiB of headers, and inline messages 10 deep admit far more, and every
// inline message/rfc822 level keeps its own copy of the nested message.
const PARSE_LIMITS = {
	maxNestingDepth: 32,
	maxPartCount: 1000,
	maxHeadersSize: 256 * 1024,
	maxRfc822NestingDepth: 2,
} satisfies PostalMimeOptions

// The body is classification context in the workflow payload, so it is cut to a bounded length.
const MAXIMUM_BODY_CHARACTERS = 4000

/** Parses under PARSE_LIMITS and returns undefined for a message beyond them. */
export async function parseMailWithinLimits(
	content: Uint8Array<ArrayBuffer>,
	options: Pick<PostalMimeOptions, "attachmentEncoding"> = {},
): Promise<Email | undefined> {
	try {
		return await PostalMime.parse(content, { ...PARSE_LIMITS, ...options })
	} catch (error) {
		if (error instanceof Error && "code" in error && String(error.code).startsWith("EMAX")) return undefined
		throw error
	}
}

export function mailContextOf(email: Email, senderAddress: string): MailContext {
	return {
		senderAddress,
		subject: email.subject?.trim() ?? "",
		bodyText: (email.text ?? "").trim().slice(0, MAXIMUM_BODY_CHARACTERS),
	}
}

function escapeMarkup(text: string): string {
	return text.replace(/[&<>"']/g, (character) => `&#${character.charCodeAt(0)};`)
}

function decodedContentIdentifier(reference: string): string {
	try {
		return decodeURIComponent(reference)
	} catch {
		return reference
	}
}

/** Inline images have no address a browser can load, so each cid: reference becomes a data: URI. */
function embedInlineImages(html: string, attachments: ReadonlyArray<Attachment>): string {
	return html.replace(/cid:([^"'\s)>]+)/gi, (reference, contentIdentifier: string) => {
		const image = attachments.find(
			(attachment) =>
				attachment.mimeType.startsWith("image/") &&
				attachment.contentId?.replace(/^<|>$/g, "") === decodedContentIdentifier(contentIdentifier),
		)
		return image === undefined ? reference : `data:${image.mimeType};base64,${String(image.content)}`
	})
}

function printableHeader(email: Email): string {
	const sender = email.from?.address ?? email.from?.name
	const rows: Array<[string, string | undefined]> = [
		["Subject", email.subject],
		["From", sender],
		["Date", email.date],
	]
	const printedRows = rows
		.filter(([, value]) => value !== undefined && value !== "")
		.map(([label, value]) => `<div><b>${label}:</b> ${escapeMarkup(value ?? "")}</div>`)
	return `<div style="font:12px/1.5 sans-serif;color:#000;margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid #999">${printedRows.join("")}</div>`
}

/**
 * The page that Browser Run prints: the subject, sender, and date above the body, so the PDF
 * records where it came from. Parse the message with base64 attachments. Returns undefined for a
 * message without a body.
 */
export function composePrintableMail(email: Email): string | undefined {
	const html = email.html?.trim()
	const text = email.text?.trim()
	let body: string
	if (html !== undefined && html !== "") body = embedInlineImages(html, email.attachments)
	else if (text !== undefined && text !== "") {
		body = `<pre style="font:14px/1.5 sans-serif;white-space:pre-wrap">${escapeMarkup(text)}</pre>`
	} else return undefined
	return `<!doctype html><meta charset="utf-8">${printableHeader(email)}${body}`
}
