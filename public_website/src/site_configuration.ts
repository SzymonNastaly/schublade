export const WEBSITE_ORIGIN = "https://schublade.org"
export const REPOSITORY_URL = "https://github.com/SzymonNastaly/schublade"
export const DEPLOYMENT_GUIDE_URL = `${REPOSITORY_URL}#deploy`
export const LICENSE_URL = `${REPOSITORY_URL}/blob/main/LICENSE`
export const APP_STORE_URL = "https://apps.apple.com/app/id6838529522"

export type PlatformAvailability = "available" | "coming_soon"

export const PLATFORMS = {
	web: { label: "Web", availability: "available", path: "web/" },
	iphone: { label: "iPhone", availability: "available", path: "iphone/" },
	mac: { label: "Mac", availability: "available", path: "mac/" },
} as const satisfies Record<string, { label: string; availability: PlatformAvailability; path: string }>

export type Platform = keyof typeof PLATFORMS

export const PLATFORM_ORDER: ReadonlyArray<Platform> = ["web", "iphone", "mac"]

/** App Store Connect names these paths for the iPhone app's support and privacy policy, so they never change. */
export const INFORMATION_PAGES = ["support", "privacy", "impressum"] as const

export type InformationPage = (typeof INFORMATION_PAGES)[number]

/**
 * IndexNow proves ownership of the host by fetching this key from INDEXNOW_KEY_PATH.
 * The key is public by design; changing it only requires a deploy before the next notification.
 */
export const INDEXNOW_KEY = "bf3c5ce5e1daaf0869810092f65e88bb"
export const INDEXNOW_KEY_PATH = "/indexnow-key.txt"
