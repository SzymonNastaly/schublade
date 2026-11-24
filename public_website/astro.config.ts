import { readFileSync } from "node:fs"
import sitemap, { type SitemapItem } from "@astrojs/sitemap"
import { defineConfig } from "astro/config"
import { WEBSITE_ORIGIN } from "./src/site_configuration.ts"

const OUTPUT_DIRECTORY = new URL("./dist/", import.meta.url)

/**
 * Copies the hreflang links of each built page into its sitemap entry. A post's versions can have different
 * slugs, which the sitemap's own prefix matching cannot pair, and this keeps the sitemap equal to the HTML.
 */
function withPageAlternates(item: SitemapItem): SitemapItem {
	const { pathname } = new URL(item.url)
	const html = readFileSync(new URL(`.${pathname}index.html`, OUTPUT_DIRECTORY), "utf8")
	const links = [...html.matchAll(/<link\b[^>]*>/g)].flatMap(([tag]) => {
		const language = /\bhreflang="([^"]+)"/.exec(tag)?.[1]
		const url = /\bhref="([^"]+)"/.exec(tag)?.[1]
		return /\brel="alternate"/.test(tag) && language && url ? [{ lang: language, url }] : []
	})
	return { ...item, links }
}

export default defineConfig({
	site: WEBSITE_ORIGIN,
	output: "static",
	trailingSlash: "always",
	build: { format: "directory" },
	devToolbar: { enabled: false },
	integrations: [sitemap({ serialize: withPageAlternates })],
})
