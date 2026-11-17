import { QueryClient, QueryObserver } from "@tanstack/react-query"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { createStatusFollowing } from "./status_following"
import type { CollectorEvent, CollectorStatus } from "./collector_status"

const emptyCounts = {
	paths_stabilizing: 0,
	paths_awaiting_digest: 0,
	paths_digested: 0,
	paths_excluded: 0,
	paths_unreadable: 0,
	contents_unresolved: 0,
	contents_awaiting_submission: 0,
	contents_present: 0,
	contents_deleted: 0,
	contents_refused: 0,
	contents_failing: 0,
}

/**
 * A collector whose status read takes `readMilliseconds` and reports the revision that held when
 * the read began, as a read the coordinator answered before a later change would.
 */
function collectorWithSlowReads(readMilliseconds: number) {
	let revision = 0
	let reads = 0
	const listeners = new Set<(event: CollectorEvent) => void>()
	const bridge = {
		readStatus: async (): Promise<CollectorStatus> => {
			reads += 1
			const seen = revision
			await new Promise((resolve) => setTimeout(resolve, readMilliseconds))
			return {
				revision: seen,
				connection: { kind: "Unconfigured" },
				archive_origin: null,
				folders: [],
				counts: emptyCounts,
				activities: [],
				attention: [],
				recent_receipts: [],
			}
		},
		subscribe: (listener: (event: CollectorEvent) => void) => {
			listeners.add(listener)
			return Promise.resolve(() => void listeners.delete(listener))
		},
	}
	return {
		bridge,
		change: () => {
			revision += 1
			for (const listener of listeners) listener({ kind: "StatusChanged", revision })
		},
		announceCurrent: () => {
			for (const listener of listeners) listener({ kind: "StatusChanged", revision })
		},
		reads: () => reads,
	}
}

/** The window: the status query observed, as `useQuery` observes it, and every revision it shows. */
function openWindow(bridge: ReturnType<typeof collectorWithSlowReads>["bridge"]) {
	const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
	const following = createStatusFollowing(bridge)
	const stopFollowing = following.follow(queryClient)
	const observer = new QueryObserver(queryClient, following.statusQuery)
	const shown: Array<number> = []
	const stopObserving = observer.subscribe((result) => {
		if (result.data !== undefined && shown.at(-1) !== result.data.revision) shown.push(result.data.revision)
	})
	return {
		shown,
		close: () => {
			stopObserving()
			stopFollowing()
			queryClient.clear()
		},
	}
}

describe("following the collector's status", () => {
	beforeEach(() => {
		vi.useFakeTimers()
	})
	afterEach(() => {
		vi.useRealTimers()
	})

	it("shows a change announced while the first read is still running", async () => {
		const collector = collectorWithSlowReads(300)
		const window = openWindow(collector.bridge)

		await vi.advanceTimersByTimeAsync(50)
		collector.change()
		await vi.advanceTimersByTimeAsync(2_000)

		expect(window.shown.at(-1)).toBe(1)
		window.close()
	})

	it("keeps showing newer statuses while a busy collector announces faster than a read takes", async () => {
		const collector = collectorWithSlowReads(400)
		const window = openWindow(collector.bridge)
		await vi.advanceTimersByTimeAsync(500)

		for (let announcement = 0; announcement < 20; announcement += 1) {
			collector.change()
			await vi.advanceTimersByTimeAsync(250)
		}
		const shownDuringFiveBusySeconds = window.shown.length - 1
		await vi.advanceTimersByTimeAsync(2_000)

		expect(shownDuringFiveBusySeconds).toBeGreaterThanOrEqual(5)
		expect(window.shown.at(-1)).toBe(20)
		window.close()
	})

	it("reads nothing more for an announcement the shown status already includes", async () => {
		const collector = collectorWithSlowReads(100)
		collector.change()
		const window = openWindow(collector.bridge)
		await vi.advanceTimersByTimeAsync(500)

		collector.announceCurrent()
		await vi.advanceTimersByTimeAsync(500)

		expect(window.shown).toEqual([1])
		expect(collector.reads()).toBe(1)
		window.close()
	})
})
