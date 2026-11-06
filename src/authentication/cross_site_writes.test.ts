import { expect, test } from "vitest"
import { crossSiteWriteRejection } from "./cross_site_writes"

function request(method: string, origin?: string) {
	return new Request("https://archive.test/api/documents", {
		method,
		headers: origin === undefined ? {} : { Origin: origin },
	})
}

async function outcome(rejection: Response | undefined) {
	return rejection === undefined ? "admitted" : { status: rejection.status, body: await rejection.text() }
}

test("crossSiteWriteRejection refuses writes from another site and admits the rest", async () => {
	expect({
		crossSitePost: await outcome(crossSiteWriteRejection(request("POST", "https://attacker.example"))),
		opaqueOriginPost: await outcome(crossSiteWriteRejection(request("POST", "null"))),
		sameSitePost: await outcome(crossSiteWriteRejection(request("POST", "https://archive.test"))),
		scriptPost: await outcome(crossSiteWriteRejection(request("POST"))),
		crossSiteGet: await outcome(crossSiteWriteRejection(request("GET", "https://attacker.example"))),
	}).toEqual({
		crossSitePost: { status: 403, body: "Cross-site request refused: https://attacker.example" },
		opaqueOriginPost: { status: 403, body: "Cross-site request refused: null" },
		sameSitePost: "admitted",
		scriptPost: "admitted",
		crossSiteGet: "admitted",
	})
})
