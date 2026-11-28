import { bindings, defineConfig, triggers, exports as workerExports } from "cf/config"
import {
	readDeploymentParameters,
	readDevelopmentParameters,
	requireProvisioned,
} from "./scripts/deployment_parameters.ts"
import type {
	DeploymentParameters,
	DevelopmentParameters,
	ProvisionedParameters,
} from "./scripts/deployment_parameters.ts"

// Local development always simulates D1 under this identifier, so the `database:migrate:local`
// script in package.json and `cf dev` address the same database. Change both together.
const LOCAL_DATABASE_IDENTIFIER = "00000000-0000-4000-8000-000000000000"

/**
 * The text and JSON binding values that come from the deployment parameters. `pnpm run provision`
 * compares them with the live Worker to decide whether it must deploy again.
 */
export function parameterBindingValues(parameters: DeploymentParameters) {
	return {
		// Blank Access values make the Worker reject every browser request.
		ACCESS_TEAM_DOMAIN: parameters.accessTeamDomain ?? "",
		ACCESS_AUD: parameters.accessAudience ?? "",
		// A blank ingestion address or an empty allowlist makes the Worker reject all mail.
		INGESTION_EMAIL_ADDRESS: parameters.ingestionEmailAddress ?? "",
		MAIL_SENDER_ALLOWLIST: parameters.accessEmails ?? [],
	}
}

export function resourceNamesFor(workerName: string) {
	return {
		databaseName: `${workerName}-database`,
		documentStorageBucketName: `${workerName}-documents`,
		searchInstanceName: workerName,
		authorizationStateNamespaceTitle: `${workerName}-authorization-state`,
		aiGatewayIdentifier: workerName,
	}
}

// `cf dev` runs remote bindings through a preview of the Worker under this name. Under the
// deployed name, that preview would sit behind its Access application and demand a service
// token. scripts/evaluate_extraction.ts addresses the local Workflow under this name too.
const LOCAL_WORKER_NAME = "schublade-development"

// Builds evaluate this configuration in `production` mode or the `--mode` they receive.
// `cf dev` evaluates it in `development` mode, and commands that only read it, such as
// `cf workers types`, evaluate it without a mode.
type ConfigurationTarget =
	| { kind: "local"; workerName: string; parameters: DevelopmentParameters }
	| { kind: "deployed"; workerName: string; parameters: ProvisionedParameters }

function configurationTarget(mode: string | undefined): ConfigurationTarget {
	if (mode === undefined || mode === "development") {
		return { kind: "local", workerName: LOCAL_WORKER_NAME, parameters: readDevelopmentParameters() }
	}
	const parameters = requireProvisioned(readDeploymentParameters())
	return { kind: "deployed", workerName: parameters.workerName, parameters }
}

function resourceBindings(target: ConfigurationTarget) {
	const resourceNames = resourceNamesFor(target.workerName)
	if (target.kind === "local") {
		return {
			DATABASE: bindings.d1({ name: resourceNames.databaseName, id: LOCAL_DATABASE_IDENTIFIER }),
			DOCUMENT_STORAGE: bindings.r2({
				name: target.parameters.documentStorageBucketName ?? resourceNames.documentStorageBucketName,
			}),
			// AI Search has no local simulation. Local modes index into the remote development
			// instance, so a dev server never writes into the index of a deployment.
			SEARCH_INDEX: bindings.aiSearch({ name: resourceNames.searchInstanceName, dev: { remote: true } }),
			// @cloudflare/workers-oauth-provider reads its grants and tokens from this binding name.
			OAUTH_KV: bindings.kv(),
		}
	}
	const { databaseIdentifier, documentStorageBucketName, searchInstanceName, authorizationStateNamespaceIdentifier } =
		target.parameters
	return {
		DATABASE: bindings.d1({ name: resourceNames.databaseName, id: databaseIdentifier }),
		DOCUMENT_STORAGE: bindings.r2({ name: documentStorageBucketName }),
		SEARCH_INDEX: bindings.aiSearch({ name: searchInstanceName }),
		OAUTH_KV: bindings.kv({ id: authorizationStateNamespaceIdentifier }),
	}
}

// A custom hostname replaces workers.dev only in deployments. pnpm run provision extends the Access
// application to the custom hostname before the deployment that moves the route.
function hosting(target: ConfigurationTarget) {
	if (target.kind === "local" || target.parameters.customHostname === undefined) return {}
	return { domains: [target.parameters.customHostname], workersDev: false }
}

export default defineConfig(({ mode }) => {
	const target = configurationTarget(mode)
	const { workerName: name, parameters } = target
	const bindingValues = parameterBindingValues(parameters)
	return {
		worker: {
			name,
			compatibilityDate: "2026-11-01",
			compatibilityFlags: ["nodejs_compat"],
			entrypoint: "./src/server.ts",
			observability: { enabled: true },
			// Per-version preview hostnames are outside the Access application.
			previewUrls: false,
			...hosting(target),
			// Indexes archived documents that AI Search lacks, such as those archived before the
			// workflow indexed documents or whose index step failed. Local development does not
			// run Cron Triggers.
			triggers: [
				triggers.scheduled({ schedule: "*/15 * * * *" }),
				// `cf deploy` creates and updates the Email Routing rule that sends this address to the
				// Worker. Without an address the trigger is left out, which leaves existing rules alone.
				...(parameters.ingestionEmailAddress === undefined
					? []
					: [triggers.email({ addresses: [parameters.ingestionEmailAddress] })]),
			],
			exports: {
				DocumentIngestionWorkflow: workerExports.workflow({ name: `${name}-document-ingestion` }),
				ArchiveCoordinator: workerExports.durableObject({ storage: "sqlite" }),
			},
			env: {
				...resourceBindings(target),
				// Workers AI and Browser Run have no local simulation.
				AI_RUNTIME: bindings.ai({ dev: { remote: true } }),
				BROWSER_RENDERER: bindings.browser({ dev: { remote: true } }),
				// The local simulation applies neither the EXIF orientation nor quality.
				IMAGE_TRANSFORMER: bindings.images({ dev: { remote: true } }),
				DOCUMENT_INGESTION_WORKFLOW: bindings.workflow({
					name: `${name}-document-ingestion`,
					worker: name,
					exportName: "DocumentIngestionWorkflow",
				}),
				ARCHIVE_COORDINATOR: bindings.durableObject({ worker: name, exportName: "ArchiveCoordinator" }),
				ACCESS_TEAM_DOMAIN: bindings.text(bindingValues.ACCESS_TEAM_DOMAIN),
				ACCESS_AUD: bindings.text(bindingValues.ACCESS_AUD),
				INGESTION_EMAIL_ADDRESS: bindings.text(bindingValues.INGESTION_EMAIL_ADDRESS),
				MAIL_SENDER_ALLOWLIST: bindings.json(bindingValues.MAIL_SENDER_ALLOWLIST),
				AI_GATEWAY_IDENTIFIER: bindings.text(parameters.aiGatewayIdentifier ?? "schublade"),
				CLASSIFICATION_MODEL: bindings.text(parameters.classificationModel ?? "@cf/cloudflare/clairic-flash"),
				PERSON_ASSIGNMENT_MODEL: bindings.text(parameters.personAssignmentModel ?? "@cf/cloudflare/clef-flash"),
			},
		},
	}
})
