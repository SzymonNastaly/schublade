import type { ImageMetadata } from "astro"
import iphoneDocumentDetails from "./assets/screenshots/iphone_document_details.png"
import iphoneLibraryArriving from "./assets/screenshots/iphone_library_arriving.png"
import iphoneScanShortcuts from "./assets/screenshots/iphone_scan_shortcuts.png"
import iphoneSearchCategory from "./assets/screenshots/iphone_search_category.png"
import iphoneShareSheet from "./assets/screenshots/iphone_share_sheet.png"
import macLibraryReader from "./assets/screenshots/mac_library_reader.png"
import macTextSearch from "./assets/screenshots/mac_text_search.png"

export type ScreenshotDevice = "iphone" | "mac"

export const SCREENSHOTS = {
	iphone_library_arriving: { image: iphoneLibraryArriving, device: "iphone" },
	iphone_search_category: { image: iphoneSearchCategory, device: "iphone" },
	iphone_document_details: { image: iphoneDocumentDetails, device: "iphone" },
	iphone_share_sheet: { image: iphoneShareSheet, device: "iphone" },
	iphone_scan_shortcuts: { image: iphoneScanShortcuts, device: "iphone" },
	mac_library_reader: { image: macLibraryReader, device: "mac" },
	mac_text_search: { image: macTextSearch, device: "mac" },
} as const satisfies Record<string, { image: ImageMetadata; device: ScreenshotDevice }>

export type ScreenshotName = keyof typeof SCREENSHOTS
