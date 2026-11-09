import { MAIL_MEDIA_TYPE } from "../ingestion/source_file"
import { PdfPageBox, documentBoxFrame } from "./pdf_page_box"
import type { ListedDocument } from "../archive/document_listing"

/** The original file of a document in its box, or the reason there is no file yet. */
export function DocumentOriginal({ document }: { document: Pick<ListedDocument, "id" | "mimeType"> }) {
	if (document.mimeType === MAIL_MEDIA_TYPE) {
		return (
			<p className="p-5 text-caption">
				This email has no PDF or image attachment, and Schublade has not rendered it as a PDF yet.
			</p>
		)
	}
	const originalUrl = `/api/documents/${document.id}/original`
	return document.mimeType === "application/pdf" ? (
		<PdfPageBox url={originalUrl} />
	) : (
		<img alt="Original document" src={originalUrl} className={`${documentBoxFrame} object-contain`} />
	)
}
