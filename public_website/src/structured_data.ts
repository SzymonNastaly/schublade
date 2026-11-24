import { absoluteUrl, LOCALES, localizedPath, type Locale } from "./localization/locales.ts"
import { PLATFORMS, REPOSITORY_URL, WEBSITE_ORIGIN, type Platform } from "./site_configuration.ts"

export type StructuredData = Record<string, unknown>

export const SOCIAL_IMAGE = { path: "/social_image.png", width: 1200, height: 630 }

const ORGANIZATION = { "@type": "Organization", name: "Schublade", url: `${WEBSITE_ORIGIN}/` }

const OPERATING_SYSTEMS: Record<Platform, string> = { web: "Web browser", iphone: "iOS", mac: "macOS" }

export function webSite(locale: Locale, description: string): StructuredData {
	return {
		"@context": "https://schema.org",
		"@type": "WebSite",
		name: "Schublade",
		url: absoluteUrl(localizedPath(locale, "")),
		inLanguage: LOCALES[locale].languageTag,
		description,
	}
}

/** The software itself, or one platform of it; only an available platform carries an offer. */
export function softwareApplication(
	locale: Locale,
	pagePath: string,
	description: string,
	platforms: ReadonlyArray<Platform>,
): StructuredData {
	const available = platforms.some((platform) => PLATFORMS[platform].availability === "available")
	return {
		"@context": "https://schema.org",
		"@type": "SoftwareApplication",
		name: "Schublade",
		description,
		url: absoluteUrl(localizedPath(locale, pagePath)),
		inLanguage: LOCALES[locale].languageTag,
		applicationCategory: "BusinessApplication",
		operatingSystem: platforms.map((platform) => OPERATING_SYSTEMS[platform]).join(", "),
		image: absoluteUrl(SOCIAL_IMAGE.path),
		sameAs: REPOSITORY_URL,
		...(available ? { offers: { "@type": "Offer", price: "0", priceCurrency: "USD" } } : {}),
	}
}

export function blogPosting(
	locale: Locale,
	pagePath: string,
	post: {
		title: string
		description: string
		publishedOn: Date
		updatedOn?: Date | undefined
		tags: ReadonlyArray<string>
	},
): StructuredData {
	const url = absoluteUrl(localizedPath(locale, pagePath))
	return {
		"@context": "https://schema.org",
		"@type": "BlogPosting",
		headline: post.title,
		description: post.description,
		url,
		mainEntityOfPage: url,
		inLanguage: LOCALES[locale].languageTag,
		datePublished: post.publishedOn.toISOString().slice(0, 10),
		dateModified: (post.updatedOn ?? post.publishedOn).toISOString().slice(0, 10),
		image: absoluteUrl(SOCIAL_IMAGE.path),
		...(post.tags.length > 0 ? { keywords: post.tags.join(", ") } : {}),
		author: ORGANIZATION,
		publisher: ORGANIZATION,
	}
}

export function breadcrumbList(items: ReadonlyArray<{ name: string; path: string }>): StructuredData {
	return {
		"@context": "https://schema.org",
		"@type": "BreadcrumbList",
		itemListElement: items.map((item, index) => ({
			"@type": "ListItem",
			position: index + 1,
			name: item.name,
			item: absoluteUrl(item.path),
		})),
	}
}

/** JSON for a script element; `<` is escaped so no string inside can close the element. */
export function serializeStructuredData(data: StructuredData): string {
	return JSON.stringify(data).replaceAll("<", "\\u003c")
}
