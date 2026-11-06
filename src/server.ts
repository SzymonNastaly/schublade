import handler from "@tanstack/react-start/server-entry"
import { requireAccess } from "./authentication/access_verification"
import { crossSiteWriteRejection } from "./authentication/cross_site_writes"
import { indexMissingDocumentsOnSchedule } from "./search/document_indexing"

export { ArchiveCoordinator } from "./durable_objects/archive_coordinator"
export { DocumentIngestionWorkflow } from "./workflows/document_ingestion_workflow"

const serveApplication = (request: Request) => handler.fetch(request)
const serveWithinAccess = requireAccess(serveApplication)

// `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev` serves the application without an Access
// assertion. Builds replace `import.meta.env.DEV` with false, which removes this exemption.
const developmentExemption = import.meta.env.DEV && import.meta.env.VITE_ACCESS_DEVELOPMENT_EXEMPTION === "true"

export default {
	fetch(request, environment) {
		const rejection = crossSiteWriteRejection(request)
		if (rejection) return rejection
		return developmentExemption ? serveApplication(request) : serveWithinAccess(request, environment)
	},
	// Only the Cron Trigger in cloudflare.config.ts invokes this handler. No request reaches it,
	// so no Access assertion applies.
	scheduled: (_controller, environment) => indexMissingDocumentsOnSchedule(environment),
} satisfies ExportedHandler<Env>
