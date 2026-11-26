import { z } from "zod"
import { identifySourceFile } from "./source_file"

// Mail is markup a stranger wrote. A frame or a refresh tag would show some other page, and
// Browser Run cannot block them by resource type, because the page itself is a document too. The
// content of noscript is live markup in a browser with scripts off.
const ACTIVE_MARKUP = "script, noscript, iframe, frame, frameset, object, embed, base, meta[http-equiv]"

const MAXIMUM_REWRITE_PASSES = 16

// Images and styles still load, so a receipt looks as it was sent, and a server that never answers
// ends in the best page available. The print, the text, and the picture all open the page this way.
const MAIL_PAGE_OPTIONS = {
	setJavaScriptEnabled: false,
	allowResourceTypes: ["document", "stylesheet", "image", "font"],
	gotoOptions: { waitUntil: "networkidle0", timeout: 30_000 },
	bestAttempt: true,
	cacheTTL: 0,
} satisfies Partial<BrowserRunPDFOptions>

// A4 at 96 CSS pixels per inch, so the picture shows the top of the page in the proportion of a
// printed page, reduced to the 480 pixels on its longer side that a client's thumbnail has.
const A4_VIEWPORT = { width: 794, height: 1123 }
const THUMBNAIL_LONGER_SIDE = 480

const scrapeAnswerSchema = z.object({
	result: z.array(z.object({ results: z.array(z.object({ text: z.string() })) })),
})

type MailRenderer = Pick<BrowserRun, "quickAction">

/** Repeats until nothing changes, because removing one tag can join the text around it into a new tag. */
async function removeActiveMarkup(html: string): Promise<string> {
	let current = html
	for (let pass = 0; pass < MAXIMUM_REWRITE_PASSES; pass += 1) {
		const rewritten = await new HTMLRewriter()
			.on(ACTIVE_MARKUP, { element: (element) => void element.remove() })
			.transform(new Response(current))
			.text()
		if (rewritten === current) return current
		current = rewritten
	}
	throw new Error("The message nests active markup too deeply to print")
}

/** The page as every Browser Run action opens it. HTMLRewriter exists only in the Workers runtime. */
async function inertPage(html: string) {
	return { ...MAIL_PAGE_OPTIONS, html: await removeActiveMarkup(html) }
}

async function successfulAnswer(response: Response): Promise<Response> {
	if (!response.ok) throw new Error(`Browser Run answered ${response.status}: ${await response.text()}`)
	return response
}

/** The page as a PDF, the original of the document. */
export async function printMail(renderer: MailRenderer, html: string): Promise<Uint8Array<ArrayBuffer>> {
	const response = await successfulAnswer(
		await renderer.quickAction("pdf", {
			...(await inertPage(html)),
			pdfOptions: {
				format: "a4",
				printBackground: true,
				margin: { top: "15mm", right: "12mm", bottom: "15mm", left: "12mm" },
			},
		}),
	)
	const content = new Uint8Array(await response.arrayBuffer())
	if (identifySourceFile(content)?.kind !== "pdf") throw new Error("Browser Run did not answer with a PDF")
	return content
}

/** What the page shows, as Chromium's innerText of its body, which leaves out hidden text and styles. */
export async function readMailText(renderer: MailRenderer, html: string): Promise<string> {
	const response = await successfulAnswer(
		await renderer.quickAction("scrape", { ...(await inertPage(html)), elements: [{ selector: "body" }] }),
	)
	const body = scrapeAnswerSchema.parse(await response.json()).result[0]?.results[0]
	if (body === undefined) throw new Error("Browser Run found no body in the page")
	return body.text
}

/** The top of the page as a JPEG, the document's thumbnail. */
export async function drawMailThumbnail(renderer: MailRenderer, html: string): Promise<Uint8Array<ArrayBuffer>> {
	const response = await successfulAnswer(
		await renderer.quickAction("screenshot", {
			...(await inertPage(html)),
			viewport: A4_VIEWPORT,
			screenshotOptions: {
				type: "jpeg",
				quality: 80,
				clip: { x: 0, y: 0, ...A4_VIEWPORT, scale: THUMBNAIL_LONGER_SIDE / A4_VIEWPORT.height },
			},
		}),
	)
	const content = new Uint8Array(await response.arrayBuffer())
	if (identifySourceFile(content)?.mediaType !== "image/jpeg") throw new Error("Browser Run did not answer with a JPEG")
	return content
}
