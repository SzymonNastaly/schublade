import type { ImageMetadata } from "astro"
import iphoneDocumentDetails from "./assets/screenshots/iphone_document_details.png"
import iphoneLibraryArriving from "./assets/screenshots/iphone_library_arriving.png"
import iphoneScanShortcuts from "./assets/screenshots/iphone_scan_shortcuts.png"
import iphoneSearchCategory from "./assets/screenshots/iphone_search_category.png"
import iphoneShareSheet from "./assets/screenshots/iphone_share_sheet.png"
import macLibraryReader from "./assets/screenshots/mac_library_reader.png"
import macTextSearch from "./assets/screenshots/mac_text_search.png"
import webArchiveFilter from "./assets/screenshots/web_archive_filter.png"
import webDocumentReading from "./assets/screenshots/web_document_reading.png"
import webPhoneArchive from "./assets/screenshots/web_phone_archive.png"

export type ScreenshotFrame = "phone" | "window"

export const SCREENSHOTS = {
	iphone_library_arriving: { image: iphoneLibraryArriving, frame: "phone" },
	iphone_search_category: { image: iphoneSearchCategory, frame: "phone" },
	iphone_document_details: { image: iphoneDocumentDetails, frame: "phone" },
	iphone_share_sheet: { image: iphoneShareSheet, frame: "phone" },
	iphone_scan_shortcuts: { image: iphoneScanShortcuts, frame: "phone" },
	mac_library_reader: { image: macLibraryReader, frame: "window" },
	mac_text_search: { image: macTextSearch, frame: "window" },
	web_document_reading: { image: webDocumentReading, frame: "window" },
	web_archive_filter: { image: webArchiveFilter, frame: "window" },
	web_phone_archive: { image: webPhoneArchive, frame: "phone" },
} as const satisfies Record<string, { image: ImageMetadata; frame: ScreenshotFrame }>

export type ScreenshotName = keyof typeof SCREENSHOTS
