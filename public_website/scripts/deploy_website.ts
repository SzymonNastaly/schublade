import { spawnSync } from "node:child_process"
import { readFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import { INDEXNOW_KEY, INDEXNOW_KEY_PATH, WEBSITE_ORIGIN } from "../src/site_configuration.ts"

const BUILD_DIRECTORY = fileURLToPath(new URL("../dist/", import.meta.url))
const INDEXNOW_ENDPOINT = "https://api.indexnow.org/indexnow"
const SITEMAP_INDEX_PATH = "sitemap-index.xml"

function locations(sitemap: string): string[] {
	return [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => match[1] ?? "")
}

async function readBuiltText(path: string): Promise<string> {
	return readFile(BUILD_DIRECTORY + path, "utf8")
}

async function fetchLive(url: string): Promise<Response> {
	return fetch(url, { cache: "no-store", redirect: "manual" })
}

function builtPagePath(url: string): string {
	return `${new URL(url).pathname.slice(1)}index.html`
}

async function builtPageUrls(): Promise<string[]> {
	const sitemaps = locations(await readBuiltText(SITEMAP_INDEX_PATH))
	const pages = await Promise.all(
		sitemaps.map(async (sitemap) => locations(await readBuiltText(new URL(sitemap).pathname.slice(1)))),
	)
	return pages.flat()
}

/** An unreachable or unreadable live sitemap means the site has no pages yet, so every built page counts as new. */
async function livePageUrls(): Promise<string[]> {
	const index = await fetchLive(`${WEBSITE_ORIGIN}/${SITEMAP_INDEX_PATH}`)
	if (!index.ok) return []
	const sitemaps = await Promise.all(
		locations(await index.text()).map(async (sitemap) => {
			const response = await fetchLive(sitemap)
			return response.ok ? locations(await response.text()) : []
		}),
	)
	return sitemaps.flat()
}

async function differsFromLive(url: string): Promise<boolean> {
	const [built, live] = await Promise.all([readBuiltText(builtPagePath(url)), fetchLive(url)])
	return !live.ok || (await live.text()) !== built
}

async function changedPageUrls(): Promise<string[]> {
	const [built, live] = await Promise.all([builtPageUrls(), livePageUrls()])
	const builtSet = new Set(built)
	const altered = await Promise.all(built.map(async (url) => ((await differsFromLive(url)) ? [url] : [])))
	const removed = live.filter((url) => !builtSet.has(url))
	return [...altered.flat(), ...removed]
}

async function notifyIndexNow(urlList: string[]): Promise<void> {
	const keyLocation = WEBSITE_ORIGIN + INDEXNOW_KEY_PATH
	const servedKey = await (await fetchLive(keyLocation)).text()
	if (servedKey !== INDEXNOW_KEY) {
		throw new Error(`${keyLocation} does not serve INDEXNOW_KEY, so IndexNow would refuse the notification.`)
	}
	const response = await fetch(INDEXNOW_ENDPOINT, {
		method: "POST",
		headers: { "Content-Type": "application/json; charset=utf-8" },
		body: JSON.stringify({ host: new URL(WEBSITE_ORIGIN).host, key: INDEXNOW_KEY, keyLocation, urlList }),
	})
	if (response.status !== 200 && response.status !== 202) {
		throw new Error(`IndexNow answered ${response.status}: ${await response.text()}`)
	}
	console.log(`IndexNow accepted ${urlList.length} changed pages (${response.status}):\n${urlList.join("\n")}`)
}

const changed = await changedPageUrls()
const deployment = spawnSync("cf", ["deploy", "./dist"], { stdio: "inherit" })
if (deployment.status !== 0) process.exit(deployment.status ?? 1)

if (changed.length === 0) {
	console.log("No page differs from the previous deployment, so IndexNow is not notified.")
} else {
	await notifyIndexNow(changed)
}
