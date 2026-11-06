import handler from "@tanstack/react-start/server-entry"

export { ArchiveCoordinator } from "./durable_objects/archive_coordinator"
export { DocumentIngestionWorkflow } from "./workflows/document_ingestion_workflow"

export default {
	fetch(request) {
		return handler.fetch(request)
	},
} satisfies ExportedHandler<Env>
