import { queryOptions } from "@tanstack/react-query"
import type { QueryClient } from "@tanstack/react-query"
import type { CollectorBridge } from "./collector_bridge"

export const collectorStatusKey = ["collector_status"] as const

/**
 * Keeps the status query current from the collector's announcements, without polling. Each
 * `StatusChanged` carries the revision the status reads report, so the window reads again only
 * while the status it shows is older than the newest announcement.
 *
 * An announcement never cancels a read in flight: a busy collector announces every 250 ms, and
 * cancelling would keep any read from finishing. An announcement that arrives during a read, the
 * first one included, is answered by one more read once that read ends with an older revision.
 * The first read waits until the listener stands, so no announcement falls between the two.
 */
export function createStatusFollowing(bridge: Pick<CollectorBridge, "readStatus" | "subscribe">) {
	let announcedRevision = -1
	let markListening = () => {}
	const listening = new Promise<void>((resolve) => {
		markListening = resolve
	})

	const statusQuery = queryOptions({
		queryKey: collectorStatusKey,
		queryFn: async () => {
			await listening
			return bridge.readStatus()
		},
		staleTime: Infinity,
	})

	/** Starts following for the window's lifetime; the returned function stops it. */
	function follow(queryClient: QueryClient): () => void {
		const readAgain = () =>
			void queryClient.invalidateQueries({ queryKey: collectorStatusKey }, { cancelRefetch: false })
		const shownRevision = () => queryClient.getQueryData(statusQuery.queryKey)?.revision ?? -1

		const stopSettlementCheck = queryClient.getQueryCache().subscribe((event) => {
			if (event.type !== "updated" || event.action.type !== "success") return
			if (event.query.queryKey[0] !== collectorStatusKey[0]) return
			if (shownRevision() < announcedRevision) readAgain()
		})

		let removeListener: (() => void) | undefined
		let stopped = false
		bridge
			.subscribe((event) => {
				if (event.kind !== "StatusChanged" || event.revision <= announcedRevision) return
				announcedRevision = event.revision
				if (shownRevision() < announcedRevision) readAgain()
			})
			.then(
				(remove) => {
					if (stopped) remove()
					else removeListener = remove
				},
				() => {},
			)
			.finally(markListening)

		return () => {
			stopped = true
			removeListener?.()
			stopSettlementCheck()
		}
	}

	return { statusQuery, follow }
}
