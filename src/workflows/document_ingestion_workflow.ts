import { WorkflowEntrypoint } from "cloudflare:workers"
import { ingestDocument } from "../ingestion/document_ingestion"
import type { WorkflowEvent, WorkflowStep } from "cloudflare:workers"
import type { IngestionOutcome } from "../ingestion/document_ingestion"

interface DocumentIngestionParameters {
	documentId: string
}

export class DocumentIngestionWorkflow extends WorkflowEntrypoint<Env, DocumentIngestionParameters> {
	override run(event: WorkflowEvent<DocumentIngestionParameters>, step: WorkflowStep): Promise<IngestionOutcome> {
		return ingestDocument(step, this.env, event.payload.documentId)
	}
}
