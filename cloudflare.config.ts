import { existsSync, readFileSync } from "node:fs"
import { bindings, defineConfig, exports } from "cf/config"
import { z } from "zod"

const DEPLOYMENT_PARAMETERS_FILE = "schublade.deploy.json"

// Local development always simulates D1 under this identifier, so the `database:migrate:local`
// script in package.json and `cf dev` address the same database. Change both together.
const LOCAL_DATABASE_IDENTIFIER = "00000000-0000-4000-8000-000000000000"

// Written by `pnpm run provision` (scripts/provision_environment.ts) and ignored by git.
const deploymentParametersSchema = z.strictObject({
	workerName: z.string().min(1).optional(),
	databaseIdentifier: z.uuid().optional(),
	documentStorageBucketName: z.string().min(1).optional(),
	searchInstanceName: z.string().min(1).optional(),
	aiGatewayIdentifier: z.string().min(1).optional(),
	accessTeamDomain: z.string().optional(),
	accessAudience: z.string().optional(),
})

const deployment = deploymentParametersSchema.parse(
	existsSync(DEPLOYMENT_PARAMETERS_FILE) ? JSON.parse(readFileSync(DEPLOYMENT_PARAMETERS_FILE, "utf8")) : {},
)
const workerName = deployment.workerName ?? "schublade"
const databaseName = `${workerName}-database`

// Builds evaluate this configuration in `production` mode or the `--mode` they receive.
// `cf dev` evaluates it in `development` mode, and commands that only read it, such as
// `cf workers types`, evaluate it without a mode.
function resourceBindings(mode: string | undefined) {
	if (mode === undefined || mode === "development") {
		return {
			DATABASE: bindings.d1({ name: databaseName, id: LOCAL_DATABASE_IDENTIFIER }),
			DOCUMENT_STORAGE: bindings.r2({ name: deployment.documentStorageBucketName ?? `${workerName}-documents` }),
			// AI Search has no local simulation, so development before provisioning runs without it.
			SEARCH_INDEX: deployment.searchInstanceName !== undefined && bindings.aiSearch({ name: deployment.searchInstanceName }),
		}
	}
	// `cf deploy` provisions a new, empty resource for every D1 or R2 binding without an
	// identifier and never records it, so a build without the identifiers must not start.
	const { databaseIdentifier, documentStorageBucketName, searchInstanceName } = deployment
	if (databaseIdentifier === undefined || documentStorageBucketName === undefined || searchInstanceName === undefined) {
		throw new Error(
			`${DEPLOYMENT_PARAMETERS_FILE} does not name the D1 database, the R2 bucket, and the AI Search instance. ` +
				"Run `pnpm run provision` before building or deploying.",
		)
	}
	return {
		DATABASE: bindings.d1({ name: databaseName, id: databaseIdentifier }),
		DOCUMENT_STORAGE: bindings.r2({ name: documentStorageBucketName }),
		SEARCH_INDEX: bindings.aiSearch({ name: searchInstanceName }),
	}
}

export default defineConfig(({ mode }) => ({
	worker: {
		name: workerName,
		compatibilityDate: "2026-11-01",
		compatibilityFlags: ["nodejs_compat"],
		entrypoint: "./src/server.ts",
		observability: { enabled: true },
		// Per-version preview hostnames are outside the Access application.
		previewUrls: false,
		exports: {
			DocumentIngestionWorkflow: exports.workflow({ name: `${workerName}-document-ingestion` }),
			ArchiveCoordinator: exports.durableObject({ storage: "sqlite" }),
		},
		env: {
			...resourceBindings(mode),
			// Workers AI and Browser Run have no local simulation.
			AI_RUNTIME: bindings.ai({ dev: { remote: true } }),
			BROWSER_RENDERER: bindings.browser({ dev: { remote: true } }),
			DOCUMENT_INGESTION_WORKFLOW: bindings.workflow({
				name: `${workerName}-document-ingestion`,
				worker: workerName,
				exportName: "DocumentIngestionWorkflow",
			}),
			ARCHIVE_COORDINATOR: bindings.durableObject({ worker: workerName, exportName: "ArchiveCoordinator" }),
			// Blank Access values make the Worker reject every browser request.
			ACCESS_TEAM_DOMAIN: bindings.text(deployment.accessTeamDomain ?? ""),
			ACCESS_AUD: bindings.text(deployment.accessAudience ?? ""),
			AI_GATEWAY_IDENTIFIER: bindings.text(deployment.aiGatewayIdentifier ?? "schublade"),
		},
	},
}))
