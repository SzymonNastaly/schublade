import { useQuery } from "@tanstack/react-query"
import { MAXIMUM_DOCUMENTS_PER_STATUS_REQUEST } from "../ingestion/document_lifecycle"
import { retrieveDocumentStatuses } from "../utilities/server_functions"
import type { DocumentStatusRecord } from "../archive/document_listing"

const STATUS_POLLING_MILLISECONDS = 2000

const noStatusRecords: ReadonlyArray<DocumentStatusRecord> = []

/**
 * The latest record of each given document, as a new array only when one of them changes. Pass
 * only documents still being ingested. Beyond the limit of one request, the remaining documents
 * are followed as earlier ones settle and leave the list. Only this hook knows how updates arrive.
 */
export function useDocumentStatusUpdates(documentIds: ReadonlyArray<string>): ReadonlyArray<DocumentStatusRecord> {
	const watchedIds = [...documentIds].sort().slice(0, MAXIMUM_DOCUMENTS_PER_STATUS_REQUEST)
	const { data = noStatusRecords } = useQuery({
		queryKey: ["document_statuses", watchedIds],
		queryFn: () => retrieveDocumentStatuses({ data: { documentIds: watchedIds } }),
		enabled: watchedIds.length > 0,
		refetchInterval: STATUS_POLLING_MILLISECONDS,
		// An answer cached before a retry would put the document back in its failed state.
		gcTime: 0,
	})
	return data
}
