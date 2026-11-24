import { absoluteUrl } from "../localization/locales.ts"

export function GET(): Response {
	return new Response(`User-agent: *\nAllow: /\n\nSitemap: ${absoluteUrl("/sitemap-index.xml")}\n`, {
		headers: { "Content-Type": "text/plain; charset=utf-8" },
	})
}
