import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"
import type { BadgeTone } from "./controls/status_badge"

export const documentStatusBadges: Record<DocumentStatus, { label: string; tone: BadgeTone }> = {
	awaiting_rendering: { label: "Rendering email", tone: "neutral" },
	processing: { label: "Processing", tone: "neutral" },
	extracting: { label: "Extracting", tone: "processing" },
	recognizing_text: { label: "Recognizing text", tone: "processing" },
	classifying: { label: "Classifying", tone: "processing" },
	archived: { label: "Archived", tone: "success" },
	failed: { label: "Failed", tone: "failure" },
}

export const documentFailureSentences: Record<DocumentFailureReason, string> = {
	unreadable_file: "This file could not be opened.",
	unreadable_page:
		"No text could be read from this document. Send it from the Schublade app on an iPhone or a Mac, which reads scans on the device.",
	processing_error: "Processing failed. Try again.",
}
