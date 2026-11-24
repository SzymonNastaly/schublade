import { getCollection, type CollectionEntry } from "astro:content"
import { isLocale, LOCALE_CODES, type Locale, type PagePath } from "./localization/locales.ts"
import { INFORMATION_PAGES, type InformationPage } from "./site_configuration.ts"

export interface BlogPost {
	locale: Locale
	slug: string
	pagePath: PagePath
	entry: CollectionEntry<"blog">
}

export interface Comparison {
	locale: Locale
	competitorSlug: string
	pagePath: PagePath
	entry: CollectionEntry<"comparisons">
}

export interface InformationPageEntry {
	locale: Locale
	page: InformationPage
	pagePath: PagePath
	entry: CollectionEntry<"informationPages">
}

const SLUG_PATTERN = /^[a-z0-9]+(-[a-z0-9]+)*$/

function parseEntryIdentifier(collection: string, identifier: string): { locale: Locale; slug: string } {
	const [locale, slug, ...rest] = identifier.split("/")
	if (locale === undefined || !isLocale(locale) || slug === undefined || rest.length > 0) {
		throw new Error(`${collection}/${identifier}.md must sit directly in a locale directory, such as en/ or de/.`)
	}
	if (!SLUG_PATTERN.test(slug)) {
		throw new Error(`${collection}/${identifier}.md: a file name is lowercase ASCII words joined by hyphens.`)
	}
	return { locale, slug }
}

/** Every blog post, newest first; fails the build when two posts of one locale share a translationKey. */
export async function readBlogPosts(): Promise<Array<BlogPost>> {
	const posts = (await getCollection("blog")).map((entry): BlogPost => {
		const { locale, slug } = parseEntryIdentifier("blog", entry.id)
		return { locale, slug, pagePath: `blog/${slug}/`, entry }
	})
	const seen = new Map<string, BlogPost>()
	for (const post of posts) {
		const key = `${post.locale}/${post.entry.data.translationKey}`
		const earlier = seen.get(key)
		if (earlier) {
			throw new Error(
				`blog/${earlier.entry.id}.md and blog/${post.entry.id}.md share the translationKey "${post.entry.data.translationKey}" in one locale.`,
			)
		}
		seen.set(key, post)
	}
	return posts.sort((first, second) => second.entry.data.publishedOn.getTime() - first.entry.data.publishedOn.getTime())
}

export function translationsOf(posts: ReadonlyArray<BlogPost>, post: BlogPost): Array<BlogPost> {
	return posts.filter((candidate) => candidate.entry.data.translationKey === post.entry.data.translationKey)
}

export async function readComparisons(): Promise<Array<Comparison>> {
	const comparisons = (await getCollection("comparisons")).map((entry): Comparison => {
		const { locale, slug } = parseEntryIdentifier("comparisons", entry.id)
		return { locale, competitorSlug: slug, pagePath: `compare/${slug}/`, entry }
	})
	return comparisons.sort((first, second) => first.entry.data.competitor.localeCompare(second.entry.data.competitor))
}

function isInformationPage(slug: string): slug is InformationPage {
	return (INFORMATION_PAGES as ReadonlyArray<string>).includes(slug)
}

/** Every information page in the order of INFORMATION_PAGES; fails the build when a locale lacks one. */
export async function readInformationPages(): Promise<Array<InformationPageEntry>> {
	const pages = (await getCollection("informationPages")).map((entry): InformationPageEntry => {
		const { locale, slug } = parseEntryIdentifier("information_pages", entry.id)
		if (!isInformationPage(slug)) {
			throw new Error(`information_pages/${entry.id}.md: the file name must be one of ${INFORMATION_PAGES.join(", ")}.`)
		}
		return { locale, page: slug, pagePath: `${slug}/`, entry }
	})
	for (const locale of LOCALE_CODES) {
		for (const page of INFORMATION_PAGES) {
			if (!pages.some((candidate) => candidate.locale === locale && candidate.page === page)) {
				throw new Error(`information_pages/${locale}/${page}.md is missing.`)
			}
		}
	}
	return pages.sort((first, second) => INFORMATION_PAGES.indexOf(first.page) - INFORMATION_PAGES.indexOf(second.page))
}

const WORDS_PER_MINUTE = 200

export function readingMinutes(post: BlogPost): number {
	const words = (post.entry.body ?? "").split(/\s+/).filter(Boolean).length
	return Math.max(1, Math.round(words / WORDS_PER_MINUTE))
}
