import { readFileSync } from "node:fs"
import { z } from "zod"
import {
	findCloudflareResource,
	queryCloudflare,
	runCloudflare,
	runCloudflareInTerminal,
	runCommand,
	runCommandForExitCode,
} from "./command_execution.ts"
import { decideDeployment, describeDeploymentRefusal } from "./deployment_admission.ts"
import { readDeploymentParameters, requireProvisioned } from "./deployment_parameters.ts"
import {
	RELEASE_TAG_LISTING_FORMAT,
	composeVersionAnnotations,
	describeVersionRecord,
	parseCommitIdentifier,
	parseReleaseTags,
	parseRemoteReleaseCommits,
	parseVersionRecord,
} from "./deployment_record.ts"
import type {
	AdmissionFacts,
	DeploymentPlan,
	LiveDeployment,
	LiveVersion,
	OriginState,
	RelationToHead,
	RepositoryState,
} from "./deployment_admission.ts"
import type { CommitIdentifier } from "./deployment_record.ts"

const MIGRATIONS_DIRECTORY = "drizzle"
const BUILT_WORKER_CONFIGURATION = ".cloudflare/output/v0/workers/default/worker.config.json"

export class CommandRefused extends Error {
	readonly remedy: string

	constructor(description: { message: string; remedy: string }) {
		super(description.message)
		this.remedy = description.remedy
	}
}

async function git(commandArguments: Array<string>): Promise<string> {
	return (await runCommand("git", commandArguments)).standardOutput
}

/** Exit status 0 is true and 1 is false, as `git merge-base --is-ancestor` answers. */
async function gitAnswers(commandArguments: Array<string>): Promise<boolean> {
	const { exitCode, standardError } = await runCommandForExitCode("git", commandArguments)
	if (exitCode === 0 || exitCode === 1) return exitCode === 0
	throw new Error(`\`git ${commandArguments.join(" ")}\` exited with ${exitCode}:\n${standardError}`)
}

async function readWorkingTree(): Promise<{ headCommit: CommitIdentifier; modifiedPaths: Array<string> }> {
	const status = await git(["status", "--porcelain", "--untracked-files=normal"])
	return {
		headCommit: parseCommitIdentifier(await git(["rev-parse", "HEAD"])),
		modifiedPaths: status
			.split("\n")
			.filter((line) => line.length > 0)
			.map((line) => line.slice(3)),
	}
}

export async function readRepositoryState(): Promise<RepositoryState> {
	const workingTree = await readWorkingTree()
	return {
		...workingTree,
		headOnMainBranch: await gitAnswers(["merge-base", "--is-ancestor", "HEAD", "refs/heads/main"]),
		releaseTags: parseReleaseTags(
			await git(["for-each-ref", `--format=${RELEASE_TAG_LISTING_FORMAT}`, "refs/tags/archive-*"]),
		),
	}
}

export async function readOriginState(): Promise<OriginState> {
	await git(["fetch", "--quiet", "origin", "main"])
	return {
		headOnOriginMain: await gitAnswers(["merge-base", "--is-ancestor", "HEAD", "refs/remotes/origin/main"]),
		releaseCommits: parseRemoteReleaseCommits(await git(["ls-remote", "--tags", "origin", "refs/tags/archive-*"])),
	}
}

export async function relationToHead(commit: CommitIdentifier, headCommit: CommitIdentifier): Promise<RelationToHead> {
	if (commit === headCommit) return "same_commit"
	if (!(await gitAnswers(["cat-file", "-e", `${commit}^{commit}`]))) return "commit_unknown"
	return (await gitAnswers(["merge-base", "--is-ancestor", commit, headCommit])) ? "ancestor" : "not_an_ancestor"
}

const deploymentListSchema = z.object({
	deployments: z.array(z.object({ created_on: z.string(), versions: z.array(z.object({ version_id: z.string() })) })),
})
const workerVersionSchema = z.object({
	annotations: z.object({ "workers/message": z.string().optional() }).optional(),
})

export async function readLiveDeployment(workerName: string, headCommit: CommitIdentifier): Promise<LiveDeployment> {
	const listing = await findCloudflareResource(deploymentListSchema, [
		"workers",
		"deployments",
		"list",
		"--worker",
		workerName,
		"--per-page",
		"1",
	])
	const current = listing?.deployments[0]
	if (current === undefined) return { kind: "absent" }
	const versions = await Promise.all(
		current.versions.map(async ({ version_id: versionIdentifier }): Promise<LiveVersion> => {
			const version = await queryCloudflare(workerVersionSchema, [
				"workers",
				"versions",
				"get",
				versionIdentifier,
				"--worker-id",
				workerName,
			])
			const record = parseVersionRecord(version.annotations?.["workers/message"])
			if (record === undefined) return { versionIdentifier, kind: "unrecorded" }
			return {
				versionIdentifier,
				kind: "recorded",
				record,
				relationToHead: await relationToHead(record.commit, headCommit),
			}
		}),
	)
	const [first, ...others] = versions
	if (first === undefined) return { kind: "absent" }
	return { kind: "serving", deployedAt: current.created_on, versions: [first, ...others] }
}

export async function applyPendingMigrations(
	databaseIdentifier: string,
	options: { dryRun: boolean },
): Promise<{ pending: number }> {
	const directory = ["--dir", MIGRATIONS_DIRECTORY]
	const pending = await queryCloudflare(z.array(z.unknown()), [
		"d1",
		"migrations",
		"list",
		databaseIdentifier,
		...directory,
	])
	if (pending.length > 0 && !options.dryRun) {
		await runCloudflare(["d1", "migrations", "apply", databaseIdentifier, ...directory])
	}
	return { pending: pending.length }
}

function describeLiveDeployment(live: LiveDeployment): string {
	if (live.kind === "absent") return "none"
	return live.versions
		.map((version) => (version.kind === "recorded" ? describeVersionRecord(version.record) : "an unrecorded version"))
		.join(" and ")
}

export interface DeploymentReport {
	plan: DeploymentPlan
	hostname: string | undefined
	commandOutput: string
}

export async function deployWorkerVersion(options: {
	dryRun: boolean
	output: "terminal" | "captured"
}): Promise<DeploymentReport> {
	const parameters = requireProvisioned(readDeploymentParameters())
	const { workerName, databaseIdentifier } = parameters
	const hostname = parameters.customHostname ?? parameters.workerHostname
	console.log(`Deploying ${workerName}${hostname === undefined ? "" : ` (${hostname})`}`)

	const repository = await readRepositoryState()
	const facts: AdmissionFacts =
		parameters.deploymentAdmission === "releases_only"
			? { admission: "releases_only", origin: await readOriginState() }
			: { admission: "main_branch_commits" }
	const live = await readLiveDeployment(workerName, repository.headCommit)
	const decision = decideDeployment({ workerName, facts, repository, live })
	if (decision.kind === "refused") throw new CommandRefused(describeDeploymentRefusal(decision.refusal))
	const { plan } = decision
	const { tag, message } = composeVersionAnnotations(plan.record)
	console.log(`  Commit: ${describeVersionRecord(plan.record)}, admitted (${facts.admission})`)
	console.log(`  Live version: ${describeLiveDeployment(live)}`)

	if (options.dryRun) {
		const { pending } = await applyPendingMigrations(databaseIdentifier, { dryRun: true })
		console.log(`  D1 migrations: ${pending} pending, none applied`)
		const { standardOutput, standardError } = await runCloudflare(["deploy", "--dry-run"])
		console.log(`  Dry run of cf deploy: passed\n${`${standardOutput}\n${standardError}`.trim()}`)
		console.log(`  Worker version: not uploaded; it would record tag ${tag} and message "${message}"`)
		return { plan, hostname, commandOutput: "" }
	}

	await runCloudflare(["build"])
	const built = await readWorkingTree()
	if (built.headCommit !== plan.record.commit || built.modifiedPaths.length > 0) {
		throw new Error(
			`The checkout moved during the build: HEAD is ${built.headCommit.slice(0, 7)} with ${built.modifiedPaths.length} modified paths. Nothing was migrated or uploaded.`,
		)
	}
	const builtWorkerName = z
		.object({ name: z.string() })
		.parse(JSON.parse(readFileSync(BUILT_WORKER_CONFIGURATION, "utf8"))).name
	if (builtWorkerName !== workerName)
		throw new Error(`The build names the Worker ${builtWorkerName}, not ${workerName}.`)
	console.log("  Build: built")

	const { pending } = await applyPendingMigrations(databaseIdentifier, { dryRun: false })
	console.log(`  D1 migrations: ${pending === 0 ? "none pending" : `applied ${pending}`}`)

	const deployArguments = ["deploy", "--prebuilt", "--tag", tag, "--message", message]
	let commandOutput = ""
	if (options.output === "terminal") await runCloudflareInTerminal(deployArguments)
	else {
		const { standardOutput, standardError } = await runCloudflare(deployArguments)
		commandOutput = `${standardOutput}\n${standardError}`
	}

	const deployed = await readLiveDeployment(workerName, plan.record.commit)
	const [version, ...otherVersions] = deployed.kind === "serving" ? deployed.versions : []
	if (
		version?.kind !== "recorded" ||
		otherVersions.length > 0 ||
		version.record.commit !== plan.record.commit ||
		version.record.release !== plan.record.release
	) {
		throw new Error(
			`The upload finished, but the Worker serves ${describeLiveDeployment(deployed)}, not one version recording "${message}". Inspect it with \`pnpm exec cf workers deployments list --worker ${workerName}\`.`,
		)
	}
	console.log(`  Worker version: ${version.versionIdentifier}, recorded as ${tag}`)
	return { plan, hostname, commandOutput }
}
