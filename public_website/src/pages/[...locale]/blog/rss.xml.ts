import rss from "@astrojs/rss"
import type { APIContext } from "astro"
import { readBlogPosts } from "../../../content_entries.ts"
import { INTERFACE_TEXT } from "../../../localization/interface_text.ts"
import { absoluteUrl, LOCALES, localeParameters, localizedPath, type Locale } from "../../../localization/locales.ts"

export function getStaticPaths() {
	return localeParameters()
}

export async function GET({ props }: APIContext<{ locale: Locale }>): Promise<Response> {
	const { locale } = props
	const text = INTERFACE_TEXT[locale].blogIndex
	const posts = (await readBlogPosts()).filter((post) => post.locale === locale)
	return rss({
		title: text.title,
		description: text.description,
		site: absoluteUrl(localizedPath(locale, "blog/")),
		trailingSlash: true,
		customData: `<language>${LOCALES[locale].languageTag}</language>`,
		items: posts.map((post) => ({
			title: post.entry.data.title,
			description: post.entry.data.description,
			pubDate: post.entry.data.publishedOn,
			link: absoluteUrl(localizedPath(locale, post.pagePath)),
			categories: post.entry.data.tags,
		})),
	})
}
