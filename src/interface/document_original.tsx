import { Link, Text } from "@cloudflare/kumo"
import { PdfPageBox, documentBoxFrame } from "./pdf_page_box"
import type { ListedDocument } from "../archive/document_listing"

/** The original file of a document in its box, with a link to the file, or the reason there is no file yet. */
export function DocumentOriginal({ document }: { document: ListedDocument }) {
	if (document.status === "awaiting_rendering") {
		return (
			<Text variant="secondary">
				This email has no PDF or image attachment. Schublade stores the message and will archive it once it can render
				the email as a PDF.
			</Text>
		)
	}
	const originalUrl = `/api/documents/${document.id}/original`
	return (
		<div className="flex flex-wrap items-center gap-x-4 gap-y-1 md:sticky md:top-6">
			{document.mimeType === "application/pdf" ? (
				<PdfPageBox url={originalUrl} />
			) : (
				<img alt="Original document" src={originalUrl} className={`${documentBoxFrame} object-contain`} />
			)}
			<Link
				href={originalUrl}
				target="_blank"
				rel="noopener"
				variant="current"
				className="ml-auto text-sm text-kumo-subtle max-md:inline-flex max-md:min-h-11 max-md:items-center"
			>
				Open original <Link.ExternalIcon />
			</Link>
		</div>
	)
}
