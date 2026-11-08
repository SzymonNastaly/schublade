import { expect, test } from "vitest"
import scannedInvoice from "../../test_fixtures/documents/electricity_invoice_scanned.pdf"
import { printMail } from "./mail_rendering"

async function printedMarkup(html: string): Promise<string> {
	let printed = ""
	await printMail(
		{
			quickAction: (_action: string, options: { html: string }) => {
				printed = options.html
				return Promise.resolve(new Response(scannedInvoice))
			},
		} as unknown as Pick<BrowserRun, "quickAction">,
		html,
	)
	return printed
}

test("printMail removes active markup, including tags that a removal joins together and the content of noscript", async () => {
	const pages = await Promise.all([
		printedMarkup('<p>Total</p><script>steal()</script><iframe src="https://elsewhere.example/"></iframe>'),
		printedMarkup(
			'<p>Total</p><<iframe></iframe>meta http-equiv="refresh" content="0;url=https://elsewhere.example/">',
		),
		printedMarkup('<p>Total</p><<script></script>iframe src="https://elsewhere.example/">'),
		printedMarkup(
			'<p>Total</p><noscript><meta http-equiv="refresh" content="0;url=https://elsewhere.example/"></noscript>',
		),
	])

	expect(pages).toEqual(["<p>Total</p>", "<p>Total</p>", "<p>Total</p>", "<p>Total</p>"])
})

test("printMail refuses markup nested deeper than it will rewrite", async () => {
	const nested = "<".repeat(20) + "iframe></iframe>".repeat(20)

	await expect(printedMarkup(nested)).rejects.toThrow("nests active markup too deeply")
})
