import { identifySourceFile } from "./source_file"

// Mail is markup a stranger wrote. A frame or a refresh tag would print some other page, and
// Browser Run cannot block them by resource type, because the page itself is a document too. The
// content of noscript is live markup in a browser with scripts off.
const ACTIVE_MARKUP = "script, noscript, iframe, frame, frameset, object, embed, base, meta[http-equiv]"

const MAXIMUM_REWRITE_PASSES = 16

// Images and styles still load, so a receipt looks as it was sent, and a server that never answers
// ends in the best page available.
const MAIL_PRINT_OPTIONS = {
	setJavaScriptEnabled: false,
	allowResourceTypes: ["document", "stylesheet", "image", "font"],
	gotoOptions: { waitUntil: "networkidle0", timeout: 30_000 },
	bestAttempt: true,
	cacheTTL: 0,
	pdfOptions: {
		format: "a4",
		printBackground: true,
		margin: { top: "15mm", right: "12mm", bottom: "15mm", left: "12mm" },
	},
} satisfies Partial<BrowserRunPDFOptions>

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

/** The page as a PDF. HTMLRewriter exists only in the Workers runtime. */
export async function printMail(
	renderer: Pick<BrowserRun, "quickAction">,
	html: string,
): Promise<Uint8Array<ArrayBuffer>> {
	const response = await renderer.quickAction("pdf", { ...MAIL_PRINT_OPTIONS, html: await removeActiveMarkup(html) })
	if (!response.ok) throw new Error(`Browser Run answered ${response.status}: ${await response.text()}`)
	const content = new Uint8Array(await response.arrayBuffer())
	if (identifySourceFile(content)?.kind !== "pdf") throw new Error("Browser Run did not answer with a PDF")
	return content
}
