import { WorkflowEntrypoint } from "cloudflare:workers"
import { NonRetryableError } from "cloudflare:workflows"
import { z } from "zod"
import { ingestDocument } from "../ingestion/document_ingestion"
import type { WorkflowEvent, WorkflowStep } from "cloudflare:workers"
import type { IngestionOutcome } from "../ingestion/document_ingestion"

const documentIngestionParametersSchema = z.strictObject({ documentId: z.uuid() })

type DocumentIngestionParameters = z.infer<typeof documentIngestionParametersSchema>

// Instances also start from the dashboard and the cf command-line interface, which can deliver
// the payload as a JSON string, so the payload is parsed here instead of trusted.
export class DocumentIngestionWorkflow extends WorkflowEntrypoint<Env, DocumentIngestionParameters> {
	override run(event: WorkflowEvent<DocumentIngestionParameters>, step: WorkflowStep): Promise<IngestionOutcome> {
		const parameters = documentIngestionParametersSchema.safeParse(event.payload)
		if (!parameters.success) {
			throw new NonRetryableError(`The workflow payload must be { documentId: <uuid> }: ${parameters.error.message}`)
		}
		return ingestDocument(step, this.env, parameters.data.documentId)
	}
}
