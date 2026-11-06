import handler from "@tanstack/react-start/server-entry"
import { requireAccess } from "./authentication/access_verification"

export { ArchiveCoordinator } from "./durable_objects/archive_coordinator"
export { DocumentIngestionWorkflow } from "./workflows/document_ingestion_workflow"

const serveApplication = (request: Request) => handler.fetch(request)
const serveWithinAccess = requireAccess(serveApplication)

// `VITE_ACCESS_DEVELOPMENT_EXEMPTION=true pnpm dev` serves the application without an Access
// assertion. Builds replace `import.meta.env.DEV` with false, which removes this exemption.
const developmentExemption = import.meta.env.DEV && import.meta.env.VITE_ACCESS_DEVELOPMENT_EXEMPTION === "true"

export default {
	fetch(request, environment) {
		return developmentExemption ? serveApplication(request) : serveWithinAccess(request, environment)
	},
} satisfies ExportedHandler<Env>
