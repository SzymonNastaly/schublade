import type { CollectorEvent, CollectorStatus } from "./collector_status"

export interface ApplicationPreferences {
	menu_bar_item_shown: boolean
	start_at_login: boolean
}

/**
 * Everything the window asks of the application. `#collector_bridge` resolves to the Tauri
 * implementation in the application and to fixed statuses in `--mode stand_in`. A refused command
 * rejects with a `RefusalError`.
 */
export interface CollectorBridge {
	readStatus: () => Promise<CollectorStatus>
	/** Tries the address and token against the archive first and stores them only when it accepts. */
	connectArchive: (address: string, token: string) => Promise<void>
	/** Opens the system folder picker; null when the person cancels. */
	chooseFolder: () => Promise<string | null>
	enrollFolder: (root: string) => Promise<void>
	withdrawFolder: (folder: number) => Promise<void>
	decideBacklog: (folders: Array<number>) => Promise<void>
	openDocument: (link: string) => Promise<void>
	readPreferences: () => Promise<ApplicationPreferences>
	changePreferences: (preferences: ApplicationPreferences) => Promise<ApplicationPreferences>
	/** Resolves once the listener is registered; the returned function removes it. */
	subscribe: (listener: (event: CollectorEvent) => void) => Promise<() => void>
}
