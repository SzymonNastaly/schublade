import { WEBSITE_ORIGIN } from "../site_configuration.ts"

interface LocaleDefinition {
	languageTag: string
	/** The first path segment of every page in this locale; empty for the default locale. */
	pathPrefix: string
	label: string
	openGraphLocale: string
}

export const LOCALES = {
	en: { languageTag: "en", pathPrefix: "", label: "English", openGraphLocale: "en_US" },
	de: { languageTag: "de", pathPrefix: "de", label: "Deutsch", openGraphLocale: "de_DE" },
} as const satisfies Record<string, LocaleDefinition>

export type Locale = keyof typeof LOCALES

export const DEFAULT_LOCALE: Locale = "en"

export const LOCALE_CODES = Object.keys(LOCALES) as Array<Locale>

export function isLocale(value: string): value is Locale {
	return Object.hasOwn(LOCALES, value)
}

/**
 * A page's path inside its locale, such as "" for the landing page or "blog/" for the blog,
 * always ending in a slash so canonical URLs, the sitemap, and links agree.
 */
export type PagePath = string

export function localizedPath(locale: Locale, pagePath: PagePath): string {
	const prefix = LOCALES[locale].pathPrefix
	return prefix === "" ? `/${pagePath}` : `/${prefix}/${pagePath}`
}

export function absoluteUrl(path: string): string {
	return new URL(path, WEBSITE_ORIGIN).href
}

export interface PageAlternate {
	locale: Locale
	path: string
}

export function alternatesOf(pagePath: PagePath, locales: ReadonlyArray<Locale> = LOCALE_CODES): Array<PageAlternate> {
	return locales.map((locale) => ({ locale, path: localizedPath(locale, pagePath) }))
}

export function localeParameters(): Array<{ params: { locale: string | undefined }; props: { locale: Locale } }> {
	return LOCALE_CODES.map((locale) => ({
		params: { locale: LOCALES[locale].pathPrefix || undefined },
		props: { locale },
	}))
}

export function formatDate(locale: Locale, date: Date): string {
	return new Intl.DateTimeFormat(LOCALES[locale].languageTag, { dateStyle: "long", timeZone: "UTC" }).format(date)
}
