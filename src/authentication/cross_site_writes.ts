const READ_ONLY_METHODS = new Set(["GET", "HEAD", "OPTIONS"])

// The Access session cookie rides along with a cross-site request, so a page on another site
// could make a signed-in member's browser start billed uploads or indexing. Browsers send
// Origin with every cross-site write; scripts and token-authenticated callers send none.
export function crossSiteWriteRejection(request: Request): Response | undefined {
	if (READ_ONLY_METHODS.has(request.method)) return undefined
	const origin = request.headers.get("Origin")
	if (origin === null || origin === new URL(request.url).origin) return undefined
	return new Response(`Cross-site request refused: ${origin}`, { status: 403 })
}
