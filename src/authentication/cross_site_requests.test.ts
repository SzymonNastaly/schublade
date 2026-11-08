import { expect, test } from "vitest"
import { crossSiteRequestRejection } from "./cross_site_requests"

function request(method: string, origin?: string, upgrade?: string) {
	return new Request("https://archive.test/api/documents", {
		method,
		headers: {
			...(origin === undefined ? {} : { Origin: origin }),
			...(upgrade === undefined ? {} : { Upgrade: upgrade }),
		},
	})
}

async function outcome(rejection: Response | undefined) {
	return rejection === undefined ? "admitted" : { status: rejection.status, body: await rejection.text() }
}

test("crossSiteRequestRejection refuses writes and WebSocket upgrades from another site and admits the rest", async () => {
	expect({
		crossSitePost: await outcome(crossSiteRequestRejection(request("POST", "https://attacker.example"))),
		opaqueOriginPost: await outcome(crossSiteRequestRejection(request("POST", "null"))),
		sameSitePost: await outcome(crossSiteRequestRejection(request("POST", "https://archive.test"))),
		scriptPost: await outcome(crossSiteRequestRejection(request("POST"))),
		crossSiteGet: await outcome(crossSiteRequestRejection(request("GET", "https://attacker.example"))),
		crossSiteUpgrade: await outcome(crossSiteRequestRejection(request("GET", "https://attacker.example", "websocket"))),
		sameSiteUpgrade: await outcome(crossSiteRequestRejection(request("GET", "https://archive.test", "WebSocket"))),
	}).toEqual({
		crossSitePost: { status: 403, body: "Cross-site request refused: https://attacker.example" },
		opaqueOriginPost: { status: 403, body: "Cross-site request refused: null" },
		sameSitePost: "admitted",
		scriptPost: "admitted",
		crossSiteGet: "admitted",
		crossSiteUpgrade: { status: 403, body: "Cross-site request refused: https://attacker.example" },
		sameSiteUpgrade: "admitted",
	})
})
