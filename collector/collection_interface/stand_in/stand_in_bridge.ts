import { RefusalError, parseCollectorStatus } from "../src/collector_status"
import { standInStatuses } from "./stand_in_statuses"
import type { ApplicationPreferences, CollectorBridge } from "../src/collector_bridge"
import type { CollectorEvent } from "../src/collector_status"
import type { StandInScreen } from "./stand_in_statuses"

/**
 * Serves fixed statuses in a plain browser, chosen by `?screen=setup|confirmation|folders|status`,
 * or a collector that could not start with `?screen=start_failure`. `vite --mode stand_in` resolves
 * `#collector_bridge` here; the application build never does. A token other than `valid` is
 * refused, so the setup screen can show its refusal.
 */
const requested = new URLSearchParams(window.location.search).get("screen")
const startFailed = requested === "start_failure"
let screen: StandInScreen = requested !== null && requested in standInStatuses ? (requested as StandInScreen) : "status"
let preferences: ApplicationPreferences = { menu_bar_item_shown: true, start_at_login: true }
const listeners = new Set<(event: CollectorEvent) => void>()

function show(next: StandInScreen) {
	screen = next
	for (const listener of listeners) listener({ kind: "StatusChanged", revision: standInStatuses[next].revision })
}

const answerShortly = () => new Promise((resolve) => setTimeout(resolve, 400))

export const collectorBridge: CollectorBridge = {
	readStatus: () =>
		startFailed
			? Promise.reject(new RefusalError({ kind: "CollectorNotStarted", failure: { kind: "DatabaseInUse" } }))
			: Promise.resolve(parseCollectorStatus(standInStatuses[screen])),
	connectArchive: async (_address, token) => {
		await answerShortly()
		if (token !== "valid") throw new RefusalError({ kind: "TokenRefused" })
		show("folders")
	},
	chooseFolder: () => Promise.resolve("/Users/jonas/Documents/Paperwork"),
	enrollFolder: () => Promise.resolve(),
	withdrawFolder: async () => {
		await answerShortly()
		show("status")
	},
	decideBacklog: async () => {
		await answerShortly()
		show("status")
	},
	openDocument: (link) => {
		window.open(link, "_blank")
		return Promise.resolve()
	},
	readPreferences: () => Promise.resolve(preferences),
	changePreferences: (changed) => {
		preferences = changed
		return Promise.resolve(preferences)
	},
	quitApplication: () => Promise.resolve(),
	subscribe: (listener) => {
		listeners.add(listener)
		return Promise.resolve(() => listeners.delete(listener))
	},
}
