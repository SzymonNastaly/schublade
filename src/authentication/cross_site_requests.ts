const READ_ONLY_METHODS = new Set(["GET", "HEAD", "OPTIONS"])

// The Access session cookie rides along with a cross-site request, so a page on another site
// could make a signed-in member's browser start billed uploads or indexing, or listen on the
// archive's WebSocket, which the same-origin policy does not protect. Browsers send Origin with
// every cross-site write and every WebSocket upgrade; scripts and token-authenticated callers send none.
export function crossSiteRequestRejection(request: Request): Response | undefined {
	const webSocketUpgrade = request.headers.get("Upgrade")?.toLowerCase() === "websocket"
	if (READ_ONLY_METHODS.has(request.method) && !webSocketUpgrade) return undefined
	const origin = request.headers.get("Origin")
	if (origin === null || origin === new URL(request.url).origin) return undefined
	return new Response(`Cross-site request refused: ${origin}`, { status: 403 })
}
