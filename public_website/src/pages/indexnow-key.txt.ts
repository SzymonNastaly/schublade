import { INDEXNOW_KEY } from "../site_configuration.ts"

export function GET(): Response {
	return new Response(INDEXNOW_KEY, { headers: { "Content-Type": "text/plain; charset=utf-8" } })
}
