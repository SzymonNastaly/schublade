/**
 * `pnpm run provision` creates or reuses the Cloudflare resources of one Schublade environment,
 * records the household members, and deploys the Worker behind Cloudflare Access. It writes the
 * identifiers to schublade.deploy.json, which cloudflare.config.ts reads. Every step converges, so
 * a rerun reports each resource as already present.
 *
 *   pnpm run provision --worker-name schublade-staging --access-email person@example.com \
 *     --household-members test_fixtures/documents/expected_extraction.json
 *
 * A rerun without flags reuses the saved answers.
 */
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { readFileSync } from "node:fs"
import { basename } from "node:path"
import { fileURLToPath } from "node:url"
import { parseArgs } from "node:util"
import { z } from "zod"
import { readDeploymentParameters, resourceNamesFor, writeDeploymentParameters } from "../cloudflare.config.ts"
import { searchIndexMetadataFields } from "../src/search/search_index_item.ts"
import type { DeploymentParameters } from "../cloudflare.config.ts"

const DEFAULT_WORKER_NAME = "schublade"
const MIGRATIONS_DIRECTORY = "drizzle"
const ACCESS_SESSION_DURATION = "720h"
const USAGE =
	"Usage: pnpm run provision [--worker-name <name>] [--access-email <address>]... [--household-members <file.json>]"
const RERUN = "then run `pnpm run provision` again"

const cloudflareExecutable = fileURLToPath(new URL("../node_modules/.bin/cf", import.meta.url))
const workersDevHostnamePattern = /https:\/\/([a-z0-9-]+\.[a-z0-9-]+\.workers\.dev)\b/

type StepOutcome = "created" | "updated" | "applied" | "deployed" | "already present"

interface StepReport {
	outcome: StepOutcome
	detail?: string
}

function describeCause(cause: unknown): string {
	if (cause instanceof z.ZodError) return z.prettifyError(cause)
	return cause instanceof Error ? cause.message : String(cause)
}

class StepFailure extends Error {
	readonly step: string
	readonly remedy: string

	constructor(step: string, remedy: string, cause: unknown) {
		super(describeCause(cause), { cause })
		this.step = step
		this.remedy = remedy
	}
}

async function attempt<TResult>(
	step: string,
	remedy: string,
	action: () => TResult | Promise<TResult>,
): Promise<TResult> {
	try {
		return await action()
	} catch (error) {
		throw new StepFailure(step, remedy, error)
	}
}

async function performStep<TReport extends StepReport>(
	step: string,
	remedy: string,
	action: () => Promise<TReport>,
): Promise<TReport> {
	const report = await attempt(step, remedy, action)
	console.log(`  ${step}: ${report.outcome}${report.detail === undefined ? "" : ` (${report.detail})`}`)
	return report
}

function runCommand(executable: string, commandArguments: Array<string>) {
	return new Promise<{ standardOutput: string; standardError: string }>((resolve, reject) => {
		const child = spawn(executable, commandArguments, { stdio: ["ignore", "pipe", "pipe"] })
		let standardOutput = ""
		let standardError = ""
		child.stdout.on("data", (chunk: Buffer) => (standardOutput += chunk.toString()))
		child.stderr.on("data", (chunk: Buffer) => (standardError += chunk.toString()))
		child.on("error", reject)
		child.on("close", (exitCode) => {
			if (exitCode === 0) {
				resolve({ standardOutput, standardError })
				return
			}
			const output = `${standardOutput}\n${standardError}`.trim().split("\n").slice(-40).join("\n")
			reject(
				new Error(`\`${[basename(executable), ...commandArguments].join(" ")}\` exited with ${exitCode}:\n${output}`),
			)
		})
	})
}

function runCloudflare(commandArguments: Array<string>) {
	return runCommand(cloudflareExecutable, commandArguments)
}

// List commands print a `result_info: {...}` line before the JSON document.
function parseJsonDocument(standardOutput: string): unknown {
	const start = standardOutput.search(/^[[{]/m)
	if (start === -1) throw new Error(`cf printed no JSON document:\n${standardOutput}`)
	return JSON.parse(standardOutput.slice(start))
}

async function queryCloudflare<TOutput>(schema: z.ZodType<TOutput>, commandArguments: Array<string>): Promise<TOutput> {
	const { standardOutput } = await runCloudflare(commandArguments)
	return schema.parse(parseJsonDocument(standardOutput))
}

async function findCloudflareResource<TOutput>(
	schema: z.ZodType<TOutput>,
	commandArguments: Array<string>,
): Promise<TOutput | undefined> {
	try {
		return await queryCloudflare(schema, commandArguments)
	} catch (error) {
		if (error instanceof Error && /\b404 Not Found\b/.test(error.message)) return undefined
		throw error
	}
}

const resultInformationSchema = z.object({ total_count: z.number() })

async function listCloudflareResources<TItem>(
	itemSchema: z.ZodType<TItem>,
	commandArguments: Array<string>,
): Promise<Array<TItem>> {
	const items: Array<TItem> = []
	for (let page = 1; ; page += 1) {
		const { standardOutput } = await runCloudflare([...commandArguments, "--page", String(page)])
		const pageItems = z.array(itemSchema).parse(parseJsonDocument(standardOutput))
		items.push(...pageItems)
		const resultInformation = /^result_info: (.+)$/m.exec(standardOutput)?.[1]
		const totalCount =
			resultInformation === undefined
				? items.length
				: resultInformationSchema.parse(JSON.parse(resultInformation)).total_count
		if (pageItems.length === 0 || items.length >= totalCount) return items
	}
}

function parseCommandLine(commandLine: Array<string>) {
	const { values } = parseArgs({
		// pnpm forwards a `--` separator to the script unchanged.
		args: commandLine[0] === "--" ? commandLine.slice(1) : commandLine,
		options: {
			"worker-name": { type: "string" },
			"access-email": { type: "string", multiple: true },
			"household-members": { type: "string" },
		},
	})
	return {
		workerName: values["worker-name"],
		accessEmails: values["access-email"]?.map((address) => address.trim().toLowerCase()),
		householdMembersFile: values["household-members"],
	}
}

const householdMembersDocumentSchema = z.object({ household_members: z.array(z.string().trim().min(1)).min(1) })

function readHouseholdMemberNames(path: string): Array<string> {
	return householdMembersDocumentSchema.parse(JSON.parse(readFileSync(path, "utf8"))).household_members
}

// Derived from the display name, so a rerun finds the member it recorded before instead of adding a duplicate.
function householdMemberIdentifier(displayName: string): string {
	const bytes = createHash("sha256")
		.update(`household_member\n${displayName.normalize("NFC").toLowerCase()}`)
		.digest()
		.subarray(0, 16)
	// UUID version 8 (custom) with the RFC 9562 variant.
	bytes.writeUInt8((bytes.readUInt8(6) & 0x0f) | 0x80, 6)
	bytes.writeUInt8((bytes.readUInt8(8) & 0x3f) | 0x80, 8)
	const hexadecimal = bytes.toString("hex")
	return [
		hexadecimal.slice(0, 8),
		hexadecimal.slice(8, 12),
		hexadecimal.slice(12, 16),
		hexadecimal.slice(16, 20),
		hexadecimal.slice(20),
	].join("-")
}

function containSameElements(left: ReadonlyArray<unknown>, right: ReadonlyArray<unknown>): boolean {
	const canonical = (values: ReadonlyArray<unknown>) =>
		JSON.stringify(values.map((value) => JSON.stringify(value)).sort())
	return canonical(left) === canonical(right)
}

const accountSchema = z.object({ id: z.string(), name: z.string() })

async function resolveAccount(): Promise<z.infer<typeof accountSchema>> {
	const accounts = await listCloudflareResources(accountSchema, ["accounts", "list"])
	const requestedIdentifier = process.env.CLOUDFLARE_ACCOUNT_ID
	if (requestedIdentifier !== undefined) {
		const requested = accounts.find((account) => account.id === requestedIdentifier)
		if (requested === undefined)
			throw new Error(`CLOUDFLARE_ACCOUNT_ID ${requestedIdentifier} is not a signed-in account.`)
		return requested
	}
	const [onlyAccount, ...otherAccounts] = accounts
	if (onlyAccount === undefined || otherAccounts.length > 0) {
		throw new Error(`The login reaches ${accounts.length} accounts and CLOUDFLARE_ACCOUNT_ID is not set.`)
	}
	return onlyAccount
}

const databaseSchema = z.object({ uuid: z.uuid(), name: z.string() })

async function ensureDatabase(databaseName: string): Promise<StepReport & { databaseIdentifier: string }> {
	const databases = await listCloudflareResources(databaseSchema, ["d1", "list", "--name", databaseName])
	const existing = databases.find((database) => database.name === databaseName)
	if (existing !== undefined) {
		return { outcome: "already present", detail: existing.uuid, databaseIdentifier: existing.uuid }
	}
	const created = await queryCloudflare(databaseSchema, ["d1", "create", "--name", databaseName])
	return { outcome: "created", detail: created.uuid, databaseIdentifier: created.uuid }
}

async function ensureBucket(bucketName: string): Promise<StepReport> {
	if (await findCloudflareResource(z.object({ name: z.string() }), ["r2", "buckets", "get", bucketName])) {
		return { outcome: "already present" }
	}
	await runCloudflare(["r2", "buckets", "create-by-name", bucketName])
	return { outcome: "created" }
}

async function ensureGateway(gatewayIdentifier: string): Promise<StepReport> {
	if (
		await findCloudflareResource(z.object({ id: z.string() }), ["ai-gateway", "gateways", "get", gatewayIdentifier])
	) {
		return { outcome: "already present" }
	}
	await runCloudflare([
		"ai-gateway",
		"gateways",
		"create",
		"--id",
		gatewayIdentifier,
		"--authentication",
		"--collect-logs",
		"--cache-invalidate-on-update",
		"--cache-ttl",
		"0",
		"--rate-limiting-interval",
		"0",
		"--rate-limiting-limit",
		"0",
	])
	return { outcome: "created" }
}

const searchInstanceSchema = z.object({
	ai_gateway_id: z.string().nullable(),
	custom_metadata: z.array(z.object({ field_name: z.string(), data_type: z.string() })).nullable(),
})

async function ensureSearchInstance(instanceIdentifier: string, gatewayIdentifier: string): Promise<StepReport> {
	const configuration = [
		"--ai-gateway-id",
		gatewayIdentifier,
		"--custom-metadata",
		JSON.stringify(searchIndexMetadataFields),
	]
	const existing = await findCloudflareResource(searchInstanceSchema, ["ai-search", "get", instanceIdentifier])
	if (existing === undefined) {
		await runCloudflare(["ai-search", "create", instanceIdentifier, ...configuration])
		return { outcome: "created" }
	}
	const differences = [
		containSameElements(existing.custom_metadata ?? [], searchIndexMetadataFields)
			? undefined
			: `custom_metadata was ${JSON.stringify(existing.custom_metadata)}`,
		existing.ai_gateway_id === gatewayIdentifier ? undefined : `ai_gateway_id was ${existing.ai_gateway_id}`,
	].filter((difference) => difference !== undefined)
	if (differences.length === 0) return { outcome: "already present" }
	await runCloudflare(["ai-search", "update", instanceIdentifier, ...configuration])
	return { outcome: "updated", detail: differences.join("; ") }
}

async function applyMigrations(databaseIdentifier: string): Promise<StepReport> {
	const directory = ["--dir", MIGRATIONS_DIRECTORY]
	const pending = await queryCloudflare(z.array(z.unknown()), [
		"d1",
		"migrations",
		"list",
		databaseIdentifier,
		...directory,
	])
	if (pending.length === 0) return { outcome: "already present" }
	await runCloudflare(["d1", "migrations", "apply", databaseIdentifier, ...directory])
	return { outcome: "applied", detail: `${pending.length} migration${pending.length === 1 ? "" : "s"}` }
}

const queryResultSchema = z.array(z.object({ results: z.array(z.unknown()) }))

// Inserts only: a rerun leaves members that already exist, and any later edits to them, unchanged.
async function ensureHouseholdMember(databaseIdentifier: string, displayName: string): Promise<StepReport> {
	const statement = {
		sql: "INSERT INTO household_members (id, display_name, addressee_names_json) VALUES (?1, ?2, ?3) ON CONFLICT (id) DO NOTHING RETURNING id",
		params: [householdMemberIdentifier(displayName), displayName, JSON.stringify([displayName])],
	}
	const results = await queryCloudflare(queryResultSchema, [
		"d1",
		"query",
		databaseIdentifier,
		"--body",
		JSON.stringify(statement),
	])
	const inserted = results.some((result) => result.results.length > 0)
	return { outcome: inserted ? "created" : "already present", detail: statement.params[0] }
}

// The build reads the Access values and resource identifiers from schublade.deploy.json.
async function deployWorker(parameters: DeploymentParameters): Promise<string> {
	writeDeploymentParameters(parameters)
	await runCommand("pnpm", ["build"])
	const { standardOutput, standardError } = await runCloudflare(["deploy", "--prebuilt"])
	return `${standardOutput}\n${standardError}`
}

async function ensureLockedDeployment(
	parameters: DeploymentParameters,
): Promise<StepReport & { workerHostname: string }> {
	if (parameters.workerHostname !== undefined) {
		return { outcome: "already present", detail: parameters.workerHostname, workerHostname: parameters.workerHostname }
	}
	// Blank Access values make the Worker reject every request until Access protects its hostname.
	const output = await deployWorker({ ...parameters, accessTeamDomain: undefined, accessAudience: undefined })
	const workerHostname = workersDevHostnamePattern.exec(output)?.[1]
	if (workerHostname === undefined) throw new Error(`cf deploy printed no workers.dev address:\n${output}`)
	return { outcome: "deployed", detail: workerHostname, workerHostname }
}

const organizationSchema = z.object({ auth_domain: z.hostname() })

async function findAccessOrganization(): Promise<StepReport & { teamDomain: string }> {
	const organization = await findCloudflareResource(organizationSchema, ["zero-trust", "organization", "get"])
	if (organization === undefined) throw new Error("The account has no Zero Trust organization.")
	return { outcome: "already present", detail: organization.auth_domain, teamDomain: organization.auth_domain }
}

// An organization that already signs people in keeps its own identity providers.
async function ensureIdentityProvider(): Promise<StepReport> {
	const providers = await queryCloudflare(z.array(z.object({ type: z.string() })), [
		"zero-trust",
		"identity-providers",
		"list",
	])
	if (providers.length > 0) return { outcome: "already present", detail: `${providers.length} left unchanged` }
	await runCloudflare([
		"zero-trust",
		"identity-providers",
		"create",
		"--body",
		JSON.stringify({ name: "One-time PIN", type: "onetimepin", config: {} }),
	])
	return { outcome: "created", detail: "One-time PIN" }
}

const accessPolicySchema = z.object({
	id: z.string(),
	name: z.string(),
	decision: z.string(),
	include: z.array(z.object({ email: z.object({ email: z.string() }).optional() })),
	exclude: z.array(z.unknown()),
	require: z.array(z.unknown()),
})

async function ensureAccessPolicy(
	policyName: string,
	emails: Array<string>,
): Promise<StepReport & { policyIdentifier: string }> {
	const body = JSON.stringify({
		name: policyName,
		decision: "allow",
		include: emails.map((email) => ({ email: { email } })),
	})
	const policies = await listCloudflareResources(accessPolicySchema, ["zero-trust", "access", "policies", "list"])
	const existing = policies.find((policy) => policy.name === policyName)
	if (existing === undefined) {
		const created = await queryCloudflare(accessPolicySchema, [
			"zero-trust",
			"access",
			"policies",
			"create",
			"--body",
			body,
		])
		return { outcome: "created", detail: emails.join(", "), policyIdentifier: created.id }
	}
	const matches =
		existing.decision === "allow" &&
		existing.exclude.length === 0 &&
		existing.require.length === 0 &&
		containSameElements(
			existing.include.map((rule) => rule.email?.email),
			emails,
		)
	if (matches) return { outcome: "already present", detail: emails.join(", "), policyIdentifier: existing.id }
	await runCloudflare(["zero-trust", "access", "policies", "update", existing.id, "--body", body])
	return { outcome: "updated", detail: emails.join(", "), policyIdentifier: existing.id }
}

const accessApplicationSchema = z.object({
	id: z.string(),
	name: z.string(),
	aud: z.string().min(1),
	type: z.string(),
	destinations: z.array(z.object({ type: z.string(), uri: z.string().optional() })).default([]),
	policies: z.array(z.object({ id: z.string() })).default([]),
	session_duration: z.string().optional(),
})

async function ensureAccessApplication(
	applicationName: string,
	workerHostname: string,
	policyIdentifier: string,
): Promise<StepReport & { audience: string }> {
	const destinations = [{ type: "public", uri: workerHostname }]
	const body = JSON.stringify({
		type: "self_hosted",
		name: applicationName,
		destinations,
		policies: [policyIdentifier],
		session_duration: ACCESS_SESSION_DURATION,
	})
	const applications = await listCloudflareResources(accessApplicationSchema, [
		"zero-trust",
		"access",
		"applications",
		"list",
		"--name",
		applicationName,
		"--exact",
	])
	const existing = applications.find((application) => application.name === applicationName)
	if (existing === undefined) {
		const created = await queryCloudflare(accessApplicationSchema, [
			"zero-trust",
			"access",
			"applications",
			"create",
			"--body",
			body,
		])
		return { outcome: "created", detail: `aud ${created.aud}`, audience: created.aud }
	}
	const matches =
		existing.type === "self_hosted" &&
		existing.session_duration === ACCESS_SESSION_DURATION &&
		containSameElements(existing.destinations, destinations) &&
		containSameElements(
			existing.policies.map((policy) => policy.id),
			[policyIdentifier],
		)
	if (matches) return { outcome: "already present", detail: `aud ${existing.aud}`, audience: existing.aud }
	const updated = await queryCloudflare(accessApplicationSchema, [
		"zero-trust",
		"access",
		"applications",
		"update",
		existing.id,
		"--body",
		body,
	])
	return { outcome: "updated", detail: `aud ${updated.aud}`, audience: updated.aud }
}

const deploymentListSchema = z.object({
	deployments: z.array(z.object({ versions: z.array(z.object({ version_id: z.string() })) })),
})
const workerVersionSchema = z.object({
	bindings: z.array(z.object({ name: z.string(), text: z.string().optional() })),
})

async function servesAccessValues(parameters: DeploymentParameters & { workerName: string }): Promise<boolean> {
	const listing = await findCloudflareResource(deploymentListSchema, [
		"workers",
		"deployments",
		"list",
		"--worker",
		parameters.workerName,
	])
	const current = listing?.deployments[0]
	if (current === undefined) return false
	for (const { version_id: versionIdentifier } of current.versions) {
		const version = await queryCloudflare(workerVersionSchema, [
			"workers",
			"versions",
			"get",
			versionIdentifier,
			"--worker-id",
			parameters.workerName,
		])
		const text = (bindingName: string) => version.bindings.find((binding) => binding.name === bindingName)?.text
		if (
			text("ACCESS_TEAM_DOMAIN") !== parameters.accessTeamDomain ||
			text("ACCESS_AUD") !== parameters.accessAudience
		) {
			return false
		}
	}
	return true
}

async function ensureAccessDeployment(parameters: DeploymentParameters & { workerName: string }): Promise<StepReport> {
	if (await servesAccessValues(parameters)) {
		writeDeploymentParameters(parameters)
		return { outcome: "already present" }
	}
	await deployWorker(parameters)
	return { outcome: "deployed" }
}

async function main(): Promise<void> {
	const commandLine = await attempt("Command line", USAGE, () => parseCommandLine(process.argv.slice(2)))
	const saved = readDeploymentParameters()
	const workerName = commandLine.workerName ?? saved.workerName ?? DEFAULT_WORKER_NAME
	let parameters: DeploymentParameters & { workerName: string } = {
		// Identifiers recorded under another Worker name belong to another environment.
		...(workerName === saved.workerName ? saved : {}),
		workerName,
		accessEmails: commandLine.accessEmails ?? saved.accessEmails,
		householdMembersFile: commandLine.householdMembersFile ?? saved.householdMembersFile,
	}
	const { accessEmails, householdMembersFile } = parameters
	if (accessEmails === undefined) {
		throw new StepFailure(
			"Command line",
			`Pass --access-email once for every person who may sign in. ${USAGE}`,
			"No access email address was given, and schublade.deploy.json saves none.",
		)
	}
	const householdMemberNames =
		householdMembersFile === undefined
			? []
			: await attempt(
					`Household members file ${householdMembersFile}`,
					"Pass --household-members a JSON file whose `household_members` array lists display names, such as test_fixtures/documents/expected_extraction.json.",
					() => readHouseholdMemberNames(householdMembersFile),
				)
	await attempt("Command line", USAGE, () => writeDeploymentParameters(parameters))

	const account = await attempt(
		"Cloudflare account",
		"Sign in with `pnpm exec cf auth login`. When the login reaches several accounts, set CLOUDFLARE_ACCOUNT_ID.",
		resolveAccount,
	)
	process.env.CLOUDFLARE_ACCOUNT_ID = account.id
	console.log(`Provisioning ${workerName} in ${account.name}`)

	const names = resourceNamesFor(workerName)
	const { databaseIdentifier } = await performStep(
		`D1 database ${names.databaseName}`,
		`Confirm that \`pnpm exec cf d1 list\` succeeds, ${RERUN}.`,
		() => ensureDatabase(names.databaseName),
	)
	await performStep(
		`R2 bucket ${names.documentStorageBucketName}`,
		`Enable R2 once in the Cloudflare dashboard, ${RERUN}.`,
		() => ensureBucket(names.documentStorageBucketName),
	)
	await performStep(
		`AI Gateway ${names.aiGatewayIdentifier}`,
		`Confirm that \`pnpm exec cf ai-gateway gateways list\` succeeds, ${RERUN}.`,
		() => ensureGateway(names.aiGatewayIdentifier),
	)
	await performStep(
		`AI Search instance ${names.searchInstanceName}`,
		`Inspect the instance with \`pnpm exec cf ai-search get ${names.searchInstanceName}\`, ${RERUN}.`,
		() => ensureSearchInstance(names.searchInstanceName, names.aiGatewayIdentifier),
	)
	parameters = {
		...parameters,
		databaseIdentifier,
		documentStorageBucketName: names.documentStorageBucketName,
		searchInstanceName: names.searchInstanceName,
		aiGatewayIdentifier: names.aiGatewayIdentifier,
	}
	writeDeploymentParameters(parameters)

	await performStep(
		"D1 migrations",
		`List the pending migrations with \`pnpm exec cf d1 migrations list ${databaseIdentifier} --dir ${MIGRATIONS_DIRECTORY}\`. Fix a failing migration with a new one from \`pnpm database:generate\`, never by editing an applied one, ${RERUN}.`,
		() => applyMigrations(databaseIdentifier),
	)
	for (const displayName of householdMemberNames) {
		await performStep(
			`Household member ${displayName}`,
			`Inspect the table with \`pnpm exec cf d1 query ${databaseIdentifier} --sql "SELECT * FROM household_members"\`, ${RERUN}.`,
			() => ensureHouseholdMember(databaseIdentifier, displayName),
		)
	}
	if (householdMembersFile === undefined) console.log("  Household members: none given (pass --household-members)")

	const { workerHostname } = await performStep(
		"Locked first deployment",
		`Run \`pnpm build\` and \`pnpm exec cf deploy --prebuilt\` to see the full error. If the deployment succeeded but its address was not found, add "workerHostname" to schublade.deploy.json, ${RERUN}.`,
		() => ensureLockedDeployment(parameters),
	)
	parameters = { ...parameters, workerHostname }
	writeDeploymentParameters(parameters)

	const { teamDomain } = await performStep(
		"Zero Trust organization",
		`Enable Cloudflare Zero Trust once at https://one.dash.cloudflare.com/ (the free plan covers 50 users), ${RERUN}.`,
		findAccessOrganization,
	)
	await performStep(
		"Access identity providers",
		`Add an identity provider under Zero Trust, Settings, Authentication, ${RERUN}.`,
		ensureIdentityProvider,
	)
	const policyName = `schublade ${workerName}: household`
	const { policyIdentifier } = await performStep(
		`Access policy "${policyName}"`,
		`Inspect the policy under Zero Trust, Access, Policies, ${RERUN}.`,
		() => ensureAccessPolicy(policyName, accessEmails),
	)
	const applicationName = `schublade ${workerName}`
	const { audience } = await performStep(
		`Access application "${applicationName}"`,
		`Inspect the application under Zero Trust, Access, Applications, ${RERUN}.`,
		() => ensureAccessApplication(applicationName, workerHostname, policyIdentifier),
	)

	parameters = { ...parameters, accessTeamDomain: teamDomain, accessAudience: audience }
	await performStep(
		"Deployment behind Access",
		`Run \`pnpm build\` and \`pnpm exec cf deploy --prebuilt\` to see the full error, ${RERUN}.`,
		() => ensureAccessDeployment(parameters),
	)

	console.log(`\nSchublade runs at https://${workerHostname} behind Cloudflare Access.`)
	console.log(`Sign in as ${accessEmails.join(" or ")}. Ship later code changes with \`pnpm run deploy\`.`)
}

main().catch((error: unknown) => {
	if (error instanceof StepFailure) {
		console.error(`\nStep failed: ${error.step}\n${error.message}\n\nFix: ${error.remedy}`)
	} else {
		console.error(error)
	}
	process.exitCode = 1
})
