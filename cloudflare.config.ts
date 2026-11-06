import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { bindings, defineConfig, triggers, exports as workerExports } from "cf/config"
import { z } from "zod"

const DEPLOYMENT_PARAMETERS_FILE = "schublade.deploy.json"

// Local development always simulates D1 under this identifier, so the `database:migrate:local`
// script in package.json and `cf dev` address the same database. Change both together.
const LOCAL_DATABASE_IDENTIFIER = "00000000-0000-4000-8000-000000000000"

// Written by `pnpm run provision` (scripts/provision_environment.ts) and ignored by git.
// `accessEmails` and `householdMembersFile` are command-line answers that a rerun reuses.
const deploymentParametersSchema = z.strictObject({
	workerName: z
		.string()
		.regex(/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, "use lowercase letters, digits, and inner hyphens")
		.optional(),
	accessEmails: z.array(z.email()).min(1).optional(),
	householdMembersFile: z.string().min(1).optional(),
	databaseIdentifier: z.uuid().optional(),
	documentStorageBucketName: z.string().min(1).optional(),
	searchInstanceName: z.string().min(1).optional(),
	aiGatewayIdentifier: z.string().min(1).optional(),
	workerHostname: z.hostname().optional(),
	classificationModel: z.string().min(1).optional(),
	accessTeamDomain: z.hostname().optional(),
	accessAudience: z.string().min(1).optional(),
})

export type DeploymentParameters = z.infer<typeof deploymentParametersSchema>

export function readDeploymentParameters(): DeploymentParameters {
	return deploymentParametersSchema.parse(
		existsSync(DEPLOYMENT_PARAMETERS_FILE) ? JSON.parse(readFileSync(DEPLOYMENT_PARAMETERS_FILE, "utf8")) : {},
	)
}

export function writeDeploymentParameters(parameters: DeploymentParameters): void {
	writeFileSync(
		DEPLOYMENT_PARAMETERS_FILE,
		`${JSON.stringify(deploymentParametersSchema.parse(parameters), null, "\t")}\n`,
	)
}

export function resourceNamesFor(workerName: string) {
	return {
		databaseName: `${workerName}-database`,
		documentStorageBucketName: `${workerName}-documents`,
		searchInstanceName: workerName,
		aiGatewayIdentifier: workerName,
	}
}

const deployment = readDeploymentParameters()
const workerName = deployment.workerName ?? "schublade"
const resourceNames = resourceNamesFor(workerName)

// `cf dev` runs remote bindings through a preview of the Worker under this name. Under the
// deployed name, that preview would sit behind its Access application and demand a service
// token. scripts/evaluate_extraction.ts addresses the local Workflow under this name too.
const LOCAL_WORKER_NAME = "schublade-development"

function isLocalMode(mode: string | undefined): boolean {
	return mode === undefined || mode === "development"
}

// Builds evaluate this configuration in `production` mode or the `--mode` they receive.
// `cf dev` evaluates it in `development` mode, and commands that only read it, such as
// `cf workers types`, evaluate it without a mode.
function resourceBindings(mode: string | undefined) {
	if (isLocalMode(mode)) {
		return {
			DATABASE: bindings.d1({ name: resourceNames.databaseName, id: LOCAL_DATABASE_IDENTIFIER }),
			DOCUMENT_STORAGE: bindings.r2({
				name: deployment.documentStorageBucketName ?? resourceNames.documentStorageBucketName,
			}),
			// AI Search has no local simulation. Local modes index into the remote development
			// instance, so a dev server never writes into the index of a deployment.
			SEARCH_INDEX: bindings.aiSearch({
				name: resourceNamesFor(LOCAL_WORKER_NAME).searchInstanceName,
				dev: { remote: true },
			}),
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
		DATABASE: bindings.d1({ name: resourceNames.databaseName, id: databaseIdentifier }),
		DOCUMENT_STORAGE: bindings.r2({ name: documentStorageBucketName }),
		SEARCH_INDEX: bindings.aiSearch({ name: searchInstanceName }),
	}
}

export default defineConfig(({ mode }) => {
	const name = isLocalMode(mode) ? LOCAL_WORKER_NAME : workerName
	return {
		worker: {
			name,
			compatibilityDate: "2026-11-01",
			compatibilityFlags: ["nodejs_compat"],
			entrypoint: "./src/server.ts",
			observability: { enabled: true },
			// Per-version preview hostnames are outside the Access application.
			previewUrls: false,
			// Indexes archived documents that AI Search lacks, such as those archived before the
			// workflow indexed documents or whose index step failed. Local development does not
			// run Cron Triggers.
			triggers: [triggers.scheduled({ schedule: "*/15 * * * *" })],
			exports: {
				DocumentIngestionWorkflow: workerExports.workflow({ name: `${name}-document-ingestion` }),
				ArchiveCoordinator: workerExports.durableObject({ storage: "sqlite" }),
			},
			env: {
				...resourceBindings(mode),
				// Workers AI and Browser Run have no local simulation.
				AI_RUNTIME: bindings.ai({ dev: { remote: true } }),
				BROWSER_RENDERER: bindings.browser({ dev: { remote: true } }),
				DOCUMENT_INGESTION_WORKFLOW: bindings.workflow({
					name: `${name}-document-ingestion`,
					worker: name,
					exportName: "DocumentIngestionWorkflow",
				}),
				ARCHIVE_COORDINATOR: bindings.durableObject({ worker: name, exportName: "ArchiveCoordinator" }),
				// Blank Access values make the Worker reject every browser request.
				ACCESS_TEAM_DOMAIN: bindings.text(deployment.accessTeamDomain ?? ""),
				ACCESS_AUD: bindings.text(deployment.accessAudience ?? ""),
				AI_GATEWAY_IDENTIFIER: bindings.text(deployment.aiGatewayIdentifier ?? "schublade"),
				CLASSIFICATION_MODEL: bindings.text(
					deployment.classificationModel ?? "@cf/deepseek-ai/deepseek-v4.1-flash-1017",
				),
			},
		},
	}
})
