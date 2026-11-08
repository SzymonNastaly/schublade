import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { createRouter } from "@tanstack/react-router"
import { PageLoadFailure } from "./interface/page_load_failure"
import { routeTree } from "./routeTree.gen"
import { composeSearchString, parseSearchString } from "./search/search_criteria"

export function getRouter() {
	// The server calls getRouter once per request, so no query cache is shared between requests.
	const queryClient = new QueryClient()
	return createRouter({
		routeTree,
		scrollRestoration: true,
		defaultErrorComponent: PageLoadFailure,
		// The router merges every parameter it parses into the validated search of each route,
		// so an unknown or unreadable parameter is dropped here, where the URL is read. The
		// archive page and the Pending verification review are the only pages with search parameters.
		parseSearch: parseSearchString,
		stringifySearch: composeSearchString,
		Wrap: ({ children }) => <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>,
	})
}

declare module "@tanstack/react-router" {
	interface Register {
		router: ReturnType<typeof getRouter>
	}
}
