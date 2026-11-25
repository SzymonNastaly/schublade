import type { ImageMetadata } from "astro"
import iphoneDocumentDetails from "./assets/device_mockups/iphone_document_details.png"
import iphoneLibraryArriving from "./assets/device_mockups/iphone_library_arriving.png"
import iphoneScanShortcuts from "./assets/device_mockups/iphone_scan_shortcuts.png"
import iphoneSearchCategory from "./assets/device_mockups/iphone_search_category.png"
import iphoneShareSheet from "./assets/device_mockups/iphone_share_sheet.png"
import macLibraryReader from "./assets/device_mockups/mac_library_reader.png"
import macTextSearch from "./assets/device_mockups/mac_text_search.png"
import webArchiveFilter from "./assets/screenshots/web_archive_filter.png"
import webDocumentReading from "./assets/screenshots/web_document_reading.png"
import webPhoneArchive from "./assets/screenshots/web_phone_archive.png"

/**
 * How a screenshot is framed. An Apple application's image already holds Apple's bezel, composed by
 * scripts/compose_device_mockups.swift. The web app runs on any platform, and the bezel's license covers
 * only software for Apple's platforms, so its screenshots sit in the website's own browser frames.
 */
export type ScreenshotFrame = "iphone" | "macbook" | "browser_window" | "browser_phone"

/** Whether a frame is laid out beside its text as a wide picture or a tall one. */
const FRAME_SHAPES = {
	iphone: "tall",
	macbook: "wide",
	browser_window: "wide",
	browser_phone: "tall",
} as const satisfies Record<ScreenshotFrame, "wide" | "tall">

export const SCREENSHOTS = {
	iphone_library_arriving: { image: iphoneLibraryArriving, frame: "iphone" },
	iphone_search_category: { image: iphoneSearchCategory, frame: "iphone" },
	iphone_document_details: { image: iphoneDocumentDetails, frame: "iphone" },
	iphone_share_sheet: { image: iphoneShareSheet, frame: "iphone" },
	iphone_scan_shortcuts: { image: iphoneScanShortcuts, frame: "iphone" },
	mac_library_reader: { image: macLibraryReader, frame: "macbook" },
	mac_text_search: { image: macTextSearch, frame: "macbook" },
	web_document_reading: { image: webDocumentReading, frame: "browser_window" },
	web_archive_filter: { image: webArchiveFilter, frame: "browser_window" },
	web_phone_archive: { image: webPhoneArchive, frame: "browser_phone" },
} as const satisfies Record<string, { image: ImageMetadata; frame: ScreenshotFrame }>

export type ScreenshotName = keyof typeof SCREENSHOTS

export function screenshotShape(name: ScreenshotName): "wide" | "tall" {
	return FRAME_SHAPES[SCREENSHOTS[name].frame]
}
