import type { ScreenshotName } from "./screenshots.ts"
import type { Platform } from "./site_configuration.ts"

export const PLATFORM_SECTIONS = {
	web: [
		{ section: "arrival" },
		{ section: "reading" },
		{ section: "search" },
		{ section: "identity" },
		{ section: "access" },
		{ section: "requirements" },
	],
	iphone: [
		{ section: "scan", screenshot: "iphone_library_arriving" },
		{ section: "shortcuts", screenshot: "iphone_scan_shortcuts" },
		{ section: "share", screenshot: "iphone_share_sheet" },
		{ section: "library", screenshot: "iphone_search_category" },
		{ section: "details", screenshot: "iphone_document_details" },
	],
	mac: [
		{ section: "library", screenshot: "mac_library_reader" },
		{ section: "search", screenshot: "mac_text_search" },
		{ section: "collection" },
		{ section: "menuBar" },
	],
} as const satisfies Record<Platform, ReadonlyArray<{ section: string; screenshot?: ScreenshotName }>>

export type PlatformSectionName<P extends Platform> = (typeof PLATFORM_SECTIONS)[P][number]["section"]
