import PostalMime from "postal-mime"
import { expect, test } from "vitest"
import { composePrintableMail, mailContextOf } from "./mail_message"

const header = ["From: Paperlark <orders@paperlark.example>", "Subject: Order <42> & receipt", "MIME-Version: 1.0"]

const parse = (lines: Array<string>) => PostalMime.parse(lines.join("\r\n"), { attachmentEncoding: "base64" })

test("composePrintableMail puts the escaped subject and sender above the HTML body and embeds inline images", async () => {
	const email = await parse([
		...header,
		'Content-Type: multipart/related; boundary="part"',
		"",
		"--part",
		"Content-Type: text/html; charset=utf-8",
		"",
		'<p>Total 12,99 EUR</p><img src="cid:logo@paperlark.example"><img src="cid:missing@paperlark.example">',
		"--part",
		"Content-Type: image/png",
		"Content-ID: <logo@paperlark.example>",
		"Content-Transfer-Encoding: base64",
		"",
		"iVBORw0KGgo=",
		"--part--",
		"",
	])

	const page = composePrintableMail(email)

	expect(page).toContain("Order &#60;42&#62; &#38; receipt")
	expect(page).toContain("orders@paperlark.example")
	expect(page).toContain("<p>Total 12,99 EUR</p>")
	expect(page).toContain('<img src="data:image/png;base64,iVBORw0KGgo=">')
	expect(page).toContain('<img src="cid:missing@paperlark.example">')
})

test("composePrintableMail escapes a plain-text body, and a message without a body has no page", async () => {
	const plain = await parse([...header, "Content-Type: text/plain; charset=utf-8", "", "Total <b>12,99</b> EUR"])
	const empty = await parse([...header, "Content-Type: text/plain; charset=utf-8", "", ""])

	expect(composePrintableMail(plain)).toContain("Total &#60;b&#62;12,99&#60;/b&#62; EUR")
	expect(composePrintableMail(empty)).toBeUndefined()
})

test("composePrintableMail leaves a malformed cid reference as it is", async () => {
	const email = await parse([
		...header,
		'Content-Type: multipart/related; boundary="part"',
		"",
		"--part",
		"Content-Type: text/html; charset=utf-8",
		"",
		"<p>cid:50% off</p>",
		"--part",
		"Content-Type: image/png",
		"Content-ID: <logo@paperlark.example>",
		"Content-Transfer-Encoding: base64",
		"",
		"iVBORw0KGgo=",
		"--part--",
		"",
	])

	expect(composePrintableMail(email)).toContain("<p>cid:50% off</p>")
})

test("mailContextOf bounds the body that travels in the workflow payload", async () => {
	const email = await parse([...header, "Content-Type: text/plain; charset=utf-8", "", "x".repeat(5000)])

	const context = mailContextOf(email, "mira@example.com")

	expect({ ...context, bodyText: context.bodyText.length }).toEqual({
		senderAddress: "mira@example.com",
		subject: "Order <42> & receipt",
		bodyText: 4000,
	})
})
