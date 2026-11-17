import { invoke } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { open } from "@tauri-apps/plugin-dialog"
import { openUrl } from "@tauri-apps/plugin-opener"
import { RefusalError, fromExternalTag, parseCollectorStatus, refusalOf } from "./collector_status"
import type { ApplicationPreferences, CollectorBridge } from "./collector_bridge"
import type { CollectorEvent, WireCollectorEvent, WireCollectorStatus } from "./collector_status"

/** The event name `collection_application` emits every core event under. */
const COLLECTOR_EVENT = "collector_event"

/** A rejection as the window shows it: a refusal it words itself, or an error with Tauri's own text. */
function rejectionError(rejection: unknown): Error {
	const refusal = refusalOf(rejection)
	if (refusal !== null) return new RefusalError(refusal)
	if (rejection instanceof Error) return rejection
	return new Error(typeof rejection === "string" ? rejection : JSON.stringify(rejection))
}

async function command<TAnswer>(name: string, argumentsOfCommand = {}): Promise<TAnswer> {
	try {
		return await invoke<TAnswer>(name, argumentsOfCommand)
	} catch (rejection) {
		throw rejectionError(rejection)
	}
}

export const collectorBridge: CollectorBridge = {
	readStatus: async () => parseCollectorStatus(await command<WireCollectorStatus>("read_collector_status")),
	connectArchive: (address, token) => command("connect_archive", { address, token }),
	chooseFolder: async () => {
		const chosen = await open({ directory: true, multiple: false, title: "Choose a folder to collect from" }).catch(
			(rejection: unknown) => {
				throw rejectionError(rejection)
			},
		)
		return typeof chosen === "string" ? chosen : null
	},
	enrollFolder: (root) => command("enroll_folder", { root }),
	withdrawFolder: (folder) => command("withdraw_folder", { folder }),
	decideBacklog: (folders) => command("decide_backlog", { folders }),
	openDocument: (link) => openUrl(link),
	readPreferences: () => command<ApplicationPreferences>("read_application_preferences"),
	changePreferences: (preferences) =>
		command<ApplicationPreferences>("change_application_preferences", { preferences }),
	quitApplication: () => command("quit_application"),
	subscribe: async (listener) =>
		listen<WireCollectorEvent>(COLLECTOR_EVENT, (event) => listener(fromExternalTag<CollectorEvent>(event.payload))),
}
