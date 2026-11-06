import handler from "@tanstack/react-start/server-entry"
import { createRequestDispatcher } from "./request_dispatch"
import { indexMissingDocumentsOnSchedule } from "./search/document_indexing"
import type { Caller } from "./authorization/caller_authorization"

export { ArchiveCoordinator } from "./durable_objects/archive_coordinator"
export { DocumentIngestionWorkflow } from "./workflows/document_ingestion_workflow"

declare module "@tanstack/react-router" {
	interface Register {
		// Server functions and server routes read the caller that the Worker entry established.
		server: { requestContext: { caller: Caller } }
	}
}

// `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev` serves the application without an Access
// assertion. Builds replace `import.meta.env.DEV` with false, which removes this exemption.
const developmentExemption = import.meta.env.DEV && import.meta.env.VITE_ACCESS_DEVELOPMENT_EXEMPTION === "true"

const dispatchRequest = createRequestDispatcher(
	(request: Request, caller: Caller) => handler.fetch(request, { context: { caller } }),
	developmentExemption,
)

export default {
	fetch: (request, environment) => dispatchRequest(request, environment),
	// Only the Cron Trigger in cloudflare.config.ts invokes this handler. No request reaches it,
	// so no Access assertion applies.
	scheduled: (_controller, environment) => indexMissingDocumentsOnSchedule(environment),
} satisfies ExportedHandler<Env>
