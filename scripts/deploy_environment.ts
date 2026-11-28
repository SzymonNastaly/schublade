/**
 * `pnpm run deploy [-- --dry-run]` deploys HEAD to the one environment this clone names in
 * schublade.deploy.json: it refuses a commit the environment does not admit, builds, applies
 * pending D1 migrations, uploads the version with the commit it was built from, and asks the
 * Worker one unauthenticated question.
 */
import { parseArgs } from "node:util"
import { describeVersionRecord } from "./deployment_record.ts"
import { CommandRefused, deployWorkerVersion } from "./worker_version_deployment.ts"

/**
 * `GET /api/v1/authorization` without a token reaches no billed service. Its 401 problem document
 * shows that the hostname serves the Worker, that Access lets the client routes through, and that
 * request dispatch reached the bearer gate.
 */
async function confirmWorkerAnswers(hostname: string): Promise<void> {
	const address = `https://${hostname}/api/v1/authorization`
	const response = await fetch(address, { redirect: "manual" })
	const contentType = response.headers.get("Content-Type") ?? ""
	if (response.status !== 401 || !contentType.startsWith("application/problem+json")) {
		throw new Error(
			`The version is live, but ${address} answered ${response.status} ${contentType}, not 401 with a problem document.`,
		)
	}
	console.log(`  Answer of ${address}: 401, as expected without a token`)
}

async function deployEnvironment(): Promise<void> {
	const commandLine = process.argv.slice(2)
	const { values } = parseArgs({
		// pnpm forwards a `--` separator to the script unchanged.
		args: commandLine[0] === "--" ? commandLine.slice(1) : commandLine,
		options: { "dry-run": { type: "boolean", default: false } },
	})
	const dryRun = values["dry-run"]
	const report = await deployWorkerVersion({ dryRun, output: "terminal" })
	const { plan, hostname } = report
	if (dryRun) {
		console.log(`\nDry run: ${plan.workerName} would serve ${describeVersionRecord(plan.record)}. Nothing was written.`)
		return
	}
	if (hostname === undefined)
		console.log("  Answer of the Worker: not asked, since schublade.deploy.json names no hostname")
	else await confirmWorkerAnswers(hostname)
	console.log(`\n${plan.workerName} serves ${describeVersionRecord(plan.record)}.`)
}

deployEnvironment().catch((error: unknown) => {
	if (error instanceof CommandRefused) {
		console.error(`\nRefused: ${error.message}\nNothing was migrated, built, or deployed.\nFix: ${error.remedy}`)
	} else {
		console.error(error instanceof Error ? `\n${error.message}` : error)
	}
	process.exitCode = 1
})
