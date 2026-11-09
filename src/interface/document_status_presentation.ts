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
	page_limit_exceeded: "This PDF needs text recognition on more than 50 pages, which is the limit.",
	unreadable_page: "A page could not be read in any orientation.",
	processing_error: "Processing failed. Try again.",
}
