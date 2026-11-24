export const WEBSITE_ORIGIN = "https://schublade.org"
export const REPOSITORY_URL = "https://github.com/SzymonNastaly/schublade"
export const DEPLOYMENT_GUIDE_URL = `${REPOSITORY_URL}#deploy`

export type PlatformAvailability = "available" | "coming_soon"

export const PLATFORMS = {
	web: { label: "Web", availability: "available", path: "web/" },
	iphone: { label: "iPhone", availability: "coming_soon", path: "iphone/" },
	mac: { label: "Mac", availability: "coming_soon", path: "mac/" },
} as const satisfies Record<string, { label: string; availability: PlatformAvailability; path: string }>

export type Platform = keyof typeof PLATFORMS

export const PLATFORM_ORDER: ReadonlyArray<Platform> = ["web", "iphone", "mac"]

/** App Store Connect names these paths for the iPhone app's support and privacy policy, so they never change. */
export const INFORMATION_PAGES = ["support", "privacy", "impressum"] as const

export type InformationPage = (typeof INFORMATION_PAGES)[number]
