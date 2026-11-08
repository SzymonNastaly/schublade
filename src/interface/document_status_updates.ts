import { useQuery } from "@tanstack/react-query"
import { AgentClient } from "agents/client"
import { useEffect, useEffectEvent } from "react"
import { ARCHIVE_CHANGES_PATH } from "../archive/archive_changes"
import { MAXIMUM_DOCUMENTS_PER_STATUS_REQUEST } from "../ingestion/document_lifecycle"
import { retrieveDocumentStatuses } from "../utilities/server_functions"
import type { DocumentStatusRecord } from "../archive/document_listing"

// Documents uploaded together announce their steps moments apart. A newer announcement discards
// a read still running, so the window has to outlast one read on a phone connection.
const ANNOUNCEMENT_COALESCING_MILLISECONDS = 1000

// An announcement can be lost, and one that arrives during a first read joins that read and
// changes nothing, so a row being watched must not depend on the next announcement.
const STATUS_RECHECK_MILLISECONDS = 20_000

const noStatusRecords: ReadonlyArray<DocumentStatusRecord> = []

const archiveChangeListeners = new Set<() => void>()
let archiveChangeSocket: AgentClient | undefined
let pendingAnnouncement: ReturnType<typeof setTimeout> | undefined

function receiveArchiveChange(): void {
	pendingAnnouncement ??= setTimeout(() => {
		pendingAnnouncement = undefined
		for (const listener of archiveChangeListeners) listener()
	}, ANNOUNCEMENT_COALESCING_MILLISECONDS)
}

/** One socket serves the whole tab. Each opening counts as a change, because the archive may have moved while it was closed. */
function listenForArchiveChanges(listener: () => void): () => void {
	archiveChangeListeners.add(listener)
	if (archiveChangeSocket === undefined) {
		archiveChangeSocket = new AgentClient({
			agent: "ArchiveCoordinator",
			// PartySocket adds the leading slash itself.
			basePath: ARCHIVE_CHANGES_PATH.slice(1),
			host: window.location.host,
		})
		archiveChangeSocket.addEventListener("open", receiveArchiveChange)
		archiveChangeSocket.addEventListener("message", receiveArchiveChange)
	}
	return () => archiveChangeListeners.delete(listener)
}

export function useArchiveChanges(onChange: () => void): void {
	const notify = useEffectEvent(onChange)
	useEffect(() => listenForArchiveChanges(() => notify()), [])
}

/**
 * The latest record of each given document, as a new array only when one of them changes. Pass
 * only documents still being ingested. Beyond the limit of one request, the remaining documents
 * are followed as earlier ones settle and leave the list.
 */
export function useDocumentStatusUpdates(documentIds: ReadonlyArray<string>): ReadonlyArray<DocumentStatusRecord> {
	const watchedIds = [...documentIds].sort().slice(0, MAXIMUM_DOCUMENTS_PER_STATUS_REQUEST)
	const { data = noStatusRecords, refetch } = useQuery({
		queryKey: ["document_statuses", watchedIds],
		queryFn: () => retrieveDocumentStatuses({ data: { documentIds: watchedIds } }),
		enabled: watchedIds.length > 0,
		refetchInterval: STATUS_RECHECK_MILLISECONDS,
		// An answer cached before a retry would put the document back in its failed state.
		gcTime: 0,
	})
	useArchiveChanges(() => {
		if (watchedIds.length > 0) void refetch()
	})
	return data
}
