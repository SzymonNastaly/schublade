import type { BadgeVariant } from "@cloudflare/kumo"
import type { DocumentFailureReason, DocumentStatus } from "../ingestion/document_lifecycle"

export const documentStatusBadges: Record<DocumentStatus, { label: string; variant: BadgeVariant }> = {
	awaiting_rendering: { label: "Rendering email", variant: "secondary" },
	processing: { label: "Processing", variant: "secondary" },
	extracting: { label: "Extracting", variant: "info" },
	recognizing_text: { label: "Recognizing text", variant: "info" },
	classifying: { label: "Classifying", variant: "info" },
	archived: { label: "Archived", variant: "success" },
	failed: { label: "Failed", variant: "error" },
}

export const documentFailureSentences: Record<DocumentFailureReason, string> = {
	unreadable_file: "This file could not be opened.",
	page_limit_exceeded: "This PDF needs text recognition on more than 50 pages, which is the limit.",
	unreadable_page: "A page could not be read. Retry turns the page and reads it again.",
	processing_error: "Processing failed. Try again.",
}
