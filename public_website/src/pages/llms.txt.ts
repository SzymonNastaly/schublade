import { readBlogPosts, readComparisons } from "../content_entries.ts"
import { INTERFACE_TEXT } from "../localization/interface_text.ts"
import { absoluteUrl, LOCALE_CODES, LOCALES, localizedPath, type Locale } from "../localization/locales.ts"
import { PLATFORM_ORDER, PLATFORMS, REPOSITORY_URL } from "../site_configuration.ts"

interface IndexedPage {
	title: string
	description: string
	pagePath: string
}

function pageLine(locale: Locale, page: IndexedPage): string {
	return `- [${page.title}](${absoluteUrl(localizedPath(locale, page.pagePath))}): ${page.description}`
}

export async function GET(): Promise<Response> {
	const posts = await readBlogPosts()
	const comparisons = await readComparisons()
	const english = INTERFACE_TEXT.en.landing
	const sections = LOCALE_CODES.map((locale) => {
		const text = INTERFACE_TEXT[locale]
		const pages: Array<IndexedPage> = [
			{ ...text.landing, pagePath: "" },
			...PLATFORM_ORDER.map((platform) => ({ ...text.platformPages[platform], pagePath: PLATFORMS[platform].path })),
			{ ...text.comparisonIndex, pagePath: "compare/" },
			...comparisons
				.filter((comparison) => comparison.locale === locale)
				.map((comparison) => ({ ...comparison.entry.data, pagePath: comparison.pagePath })),
			{ ...text.blogIndex, pagePath: "blog/" },
			...posts
				.filter((post) => post.locale === locale)
				.map((post) => ({ ...post.entry.data, pagePath: post.pagePath })),
		]
		return [`## ${LOCALES[locale].label}`, "", ...pages.map((page) => pageLine(locale, page))].join("\n")
	})
	const body = [
		"# Schublade",
		"",
		`> ${english.description}`,
		"",
		`Source code: ${REPOSITORY_URL}`,
		"",
		...sections.flatMap((section) => [section, ""]),
	].join("\n")
	return new Response(body, { headers: { "Content-Type": "text/plain; charset=utf-8" } })
}
