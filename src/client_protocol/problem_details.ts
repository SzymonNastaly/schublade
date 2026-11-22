/**
 * The reason phrase of each status an answer can carry. Every problem has the type about:blank,
 * which RFC 9457 reserves for a problem that the status code describes in full, so a client
 * reads the status and shows the detail sentence only in diagnostics.
 */
const problemTitles = {
	400: "Bad Request",
	401: "Unauthorized",
	403: "Forbidden",
	404: "Not Found",
	405: "Method Not Allowed",
	409: "Conflict",
	410: "Gone",
	413: "Content Too Large",
	415: "Unsupported Media Type",
	422: "Unprocessable Content",
	500: "Internal Server Error",
	503: "Service Unavailable",
} as const satisfies Record<number, string>

type ProblemStatus = keyof typeof problemTitles

export function problem(status: ProblemStatus, detail: string, headers: Record<string, string> = {}): Response {
	return Response.json(
		{ type: "about:blank", title: problemTitles[status], status, detail },
		{ status, headers: { ...headers, "Content-Type": "application/problem+json" } },
	)
}

export function documentNotFound(documentId: string): Response {
	return problem(404, `No document has the identifier ${documentId}`)
}

/**
 * The query parameters a route does not define, joined for a 400, which a route answers so that
 * a client sending a parameter of a newer protocol learns at once that this archive lacks it.
 */
export function undefinedParameters(request: Request, definedParameters: ReadonlyArray<string>): string | undefined {
	const names = new Set(
		[...new URL(request.url).searchParams.keys()].filter((name) => !definedParameters.includes(name)),
	)
	return names.size === 0 ? undefined : [...names].join(", ")
}
