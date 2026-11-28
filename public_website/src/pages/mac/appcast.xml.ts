import { MACINTOSH_RELEASES, type MacintoshRelease } from "../../macintosh_releases.ts"
import { WEBSITE_ORIGIN } from "../../site_configuration.ts"

function escaped(text: string): string {
	return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;")
}

function item(release: MacintoshRelease): string {
	return `		<item>
			<title>Schublade ${escaped(release.version)}</title>
			<pubDate>${new Date(release.published).toUTCString()}</pubDate>
			<sparkle:version>${escaped(release.build)}</sparkle:version>
			<sparkle:shortVersionString>${escaped(release.version)}</sparkle:shortVersionString>
			<sparkle:minimumSystemVersion>${escaped(release.minimumSystemVersion)}</sparkle:minimumSystemVersion>
			<enclosure url="${escaped(release.diskImageUrl)}" length="${release.length}" type="application/octet-stream" sparkle:edSignature="${escaped(release.edSignature)}"/>
		</item>`
}

/** The Mac app's SUFeedURL. Sparkle reads every item and offers the one with the highest build. */
export function GET(): Response {
	const feed = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
	<channel>
		<title>Schublade for Mac</title>
		<link>${WEBSITE_ORIGIN}/mac/</link>
		<language>en</language>
${MACINTOSH_RELEASES.map(item).join("\n")}
	</channel>
</rss>
`
	return new Response(feed, { headers: { "Content-Type": "application/xml; charset=utf-8" } })
}
