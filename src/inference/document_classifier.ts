import { Output, generateText } from "ai"
import { createWorkersAI } from "workers-ai-provider"
import { buildClassificationRequest } from "../ingestion/classification_prompt"
import { normalizeClassification } from "../ingestion/document_classification"
import type { ClassificationContext } from "../ingestion/classification_prompt"
import type { DocumentClassification } from "../ingestion/document_classification"

export interface ClassificationResult {
	classification: DocumentClassification
	inputTokens: number
	outputTokens: number
}

export async function classifyDocument(
	runtime: Ai,
	gatewayIdentifier: string,
	modelName: string,
	context: ClassificationContext,
): Promise<ClassificationResult> {
	const workersAi = createWorkersAI({ binding: runtime, gateway: { id: gatewayIdentifier } })
	const { schema, system, prompt } = buildClassificationRequest(context)
	const result = await generateText({
		model: workersAi(modelName),
		system,
		prompt,
		output: Output.object({ schema }),
		temperature: 0,
		// Reasoning models spend most of their output on reasoning. Without a limit, Workers AI
		// applies a model default that cut gpt-oss-120b off before it wrote any JSON.
		maxOutputTokens: 8192,
		// The workflow step retries, so the SDK does not retry on its own.
		maxRetries: 0,
	})
	return {
		classification: normalizeClassification(result.output),
		inputTokens: result.usage.inputTokens ?? 0,
		outputTokens: result.usage.outputTokens ?? 0,
	}
}
