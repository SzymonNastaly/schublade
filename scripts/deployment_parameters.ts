/**
 * The two git-ignored parameter files of a clone. A clone holds at most one deployed environment:
 *
 *   schublade.deploy.json        written only by `pnpm run provision`, read by every build mode
 *   schublade.development.json   written by hand, optional, read only by local modes
 *
 * cloudflare.config.ts chooses the file by its mode, so a local mode never sees a deployed
 * environment's identifiers or Access values, and a build never starts without the identifiers.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { z } from "zod"

const DEPLOYMENT_PARAMETERS_FILE = "schublade.deploy.json"
const DEVELOPMENT_PARAMETERS_FILE = "schublade.development.json"

// `accessEmails` and `householdMembersFile` are command-line answers that a rerun of provisioning reuses.
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
	authorizationStateNamespaceIdentifier: z.string().min(1).optional(),
	aiGatewayIdentifier: z.string().min(1).optional(),
	workerHostname: z.hostname().optional(),
	// A Clairic model for every field but the person, and a Clef model for the person.
	classificationModel: z.string().min(1).optional(),
	personAssignmentModel: z.string().min(1).optional(),
	accessTeamDomain: z.hostname().optional(),
	accessAudience: z.string().min(1).optional(),
	// The Email Routing address whose mail the Worker archives. Without it, the Worker rejects all mail.
	ingestionEmailAddress: z.email().optional(),
	// A Workers custom domain, such as staging.schublade.org, that replaces the workers.dev hostname.
	customHostname: z.hostname().optional(),
	// The custom hostname that the last deployment of `pnpm run provision` attached. cf cannot list a
	// Worker's custom domains, so a differing customHostname tells the script to deploy again.
	deployedCustomHostname: z.hostname().optional(),
})

export type DeploymentParameters = z.infer<typeof deploymentParametersSchema>

// `cf deploy` provisions a new, empty resource for every D1, R2, or KV binding without an
// identifier and never records it, so a build mode accepts only parameters that name them all.
// A new resource binding adds its key here.
const provisionedParametersSchema = deploymentParametersSchema.required({
	workerName: true,
	databaseIdentifier: true,
	documentStorageBucketName: true,
	searchInstanceName: true,
	authorizationStateNamespaceIdentifier: true,
})

export type ProvisionedParameters = z.infer<typeof provisionedParametersSchema>

// Only the values a local mode reads. A file that names a database or an Access value does not parse.
const developmentParametersSchema = deploymentParametersSchema
	.pick({
		documentStorageBucketName: true,
		aiGatewayIdentifier: true,
		classificationModel: true,
		personAssignmentModel: true,
		ingestionEmailAddress: true,
		accessEmails: true,
	})
	.strict()

export type DevelopmentParameters = z.infer<typeof developmentParametersSchema>

function readJsonFile(path: string): unknown {
	return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {}
}

export function readDeploymentParameters(): DeploymentParameters {
	return deploymentParametersSchema.parse(readJsonFile(DEPLOYMENT_PARAMETERS_FILE))
}

export function writeDeploymentParameters(parameters: DeploymentParameters): void {
	writeFileSync(
		DEPLOYMENT_PARAMETERS_FILE,
		`${JSON.stringify(deploymentParametersSchema.parse(parameters), null, "\t")}\n`,
	)
}

export function parseDevelopmentParameters(document: unknown): DevelopmentParameters {
	const result = developmentParametersSchema.safeParse(document)
	if (result.success) return result.data
	throw new Error(
		`${DEVELOPMENT_PARAMETERS_FILE} holds only what a local mode reads (${Object.keys(developmentParametersSchema.shape).join(", ")}):\n${z.prettifyError(result.error)}`,
	)
}

export function readDevelopmentParameters(): DevelopmentParameters {
	return parseDevelopmentParameters(readJsonFile(DEVELOPMENT_PARAMETERS_FILE))
}

export function requireProvisioned(parameters: DeploymentParameters): ProvisionedParameters {
	const result = provisionedParametersSchema.safeParse(parameters)
	if (result.success) return result.data
	const missingKeys = result.error.issues.map((issue) => issue.path.join("."))
	throw new Error(
		`${DEPLOYMENT_PARAMETERS_FILE} does not name ${missingKeys.join(", ")}. Run \`pnpm run provision\` before building or deploying.`,
	)
}

/**
 * The Worker a run of provisioning sets up. A clone that names a Worker stays with it, because
 * its identifiers, its Access applications, and its live version belong to that environment.
 */
export function workerNameToProvision(
	requested: string | undefined,
	saved: string | undefined,
): { kind: "named"; workerName: string } | { kind: "refused"; reason: string } {
	if (saved === undefined) return { kind: "named", workerName: requested ?? "schublade" }
	if (requested === undefined || requested === saved) return { kind: "named", workerName: saved }
	return {
		kind: "refused",
		reason: `This clone is the environment ${saved}, so it cannot provision ${requested}. Provision another environment from another clone of the repository.`,
	}
}
