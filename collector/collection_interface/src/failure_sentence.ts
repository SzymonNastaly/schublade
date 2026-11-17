import { RefusalError } from "./collector_status"
import { refusalSentence } from "./status_sentences"
import type { CollectorStatus } from "./collector_status"

/** The sentence for a failed command: a refusal in plain words, anything else as it reports itself. */
export function failureSentence(error: Error, status: Pick<CollectorStatus, "folders"> | undefined): string {
	return error instanceof RefusalError ? refusalSentence(error.refusal, status) : error.message
}
