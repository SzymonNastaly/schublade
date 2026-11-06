import { WorkflowEntrypoint } from "cloudflare:workers"
import type { WorkflowEvent, WorkflowStep } from "cloudflare:workers"

interface DocumentIngestionParameters {
	documentId: string
}

// Phase 1 implements text extraction, recognition, classification, and indexing.
export class DocumentIngestionWorkflow extends WorkflowEntrypoint<Env, DocumentIngestionParameters> {
	override run(_event: WorkflowEvent<DocumentIngestionParameters>, _step: WorkflowStep): Promise<never> {
		return Promise.reject(new Error("DocumentIngestionWorkflow is not implemented before phase 1"))
	}
}
