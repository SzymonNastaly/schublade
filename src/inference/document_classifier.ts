import { buildFieldExtractionRequest, buildPersonAssignmentRequest } from "../ingestion/classification_request"
import {
	fieldExtractionResponseSchema,
	normalizeClassification,
	personAssignmentResponseSchema,
} from "../ingestion/document_classification"
import type { ClassificationContext } from "../ingestion/classification_request"
import type { DocumentClassification } from "../ingestion/document_classification"

export interface ClassificationModels {
	/** A Clairic model, which reads every field but the person. */
	classification: string
	/** A Clef model, which chooses the household member the document concerns. */
	personAssignment: string
}

export interface ClassificationResult {
	classification: DocumentClassification
	classificationInputTokens: number
	/** Zero when the household has no members to choose from. */
	personAssignmentInputTokens: number
}

/** Both models bill input tokens only, so the input tokens measure the cost of a document. */
export async function classifyDocument(
	runtime: Ai,
	gatewayIdentifier: string,
	models: ClassificationModels,
	context: ClassificationContext,
): Promise<ClassificationResult> {
	const run = async (modelName: string, inputs: object): Promise<unknown> =>
		runtime.run(modelName, inputs as never, { gateway: { id: gatewayIdentifier } })
	const assignPerson = async () => {
		const personAssignment = buildPersonAssignmentRequest(models.personAssignment, context)
		if (personAssignment === null) return { memberId: null, inputTokens: 0 }
		const response = personAssignmentResponseSchema.parse(await run(models.personAssignment, personAssignment.request))
		const memberId = personAssignment.memberIds.get(response.answers.person.choice)
		if (memberId === undefined) {
			throw new Error(`The person assignment chose ${response.answers.person.choice}, which it was not offered`)
		}
		return { memberId, inputTokens: response.usage.input_tokens }
	}
	const [fieldExtraction, person] = await Promise.all([
		run(models.classification, buildFieldExtractionRequest(models.classification, context)).then((response) =>
			fieldExtractionResponseSchema.parse(response),
		),
		assignPerson(),
	])
	return {
		classification: normalizeClassification(fieldExtraction.answers, person.memberId),
		classificationInputTokens: fieldExtraction.usage.input_tokens,
		personAssignmentInputTokens: person.inputTokens,
	}
}
