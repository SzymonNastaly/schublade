/**
 * `pnpm release:mark` makes HEAD the next release, the annotated tag `archive-<n>`, once staging,
 * the Worker of this clone, serves exactly HEAD. The tag carries that staging version as its
 * proof. It is created locally and never pushed: the command prints the push, which needs the
 * owner's go.
 */
import { runCommand } from "./command_execution.ts"
import { decideReleaseMarking, describeReleaseMarkingRefusal } from "./deployment_admission.ts"
import { readDeploymentParameters, requireProvisioned } from "./deployment_parameters.ts"
import { composeReleaseAnnotation, releaseTagName } from "./deployment_record.ts"
import {
	CommandRefused,
	readLiveDeployment,
	readOriginState,
	readRepositoryState,
	relationToHead,
} from "./worker_version_deployment.ts"

async function markRelease(): Promise<void> {
	const { workerName, deploymentAdmission } = requireProvisioned(readDeploymentParameters())
	console.log(`Marking a release proven on ${workerName}`)
	const repository = await readRepositoryState()
	const origin = await readOriginState()
	const live = await readLiveDeployment(workerName, repository.headCommit)
	const newestRelease = repository.releaseTags.releases.at(-1)
	const marking = decideReleaseMarking({
		workerName,
		admission: deploymentAdmission ?? "main_branch_commits",
		repository,
		origin,
		live,
		newestReleaseRelation:
			newestRelease === undefined ? undefined : await relationToHead(newestRelease.commit, repository.headCommit),
	})
	if (marking.kind === "refused") throw new CommandRefused(describeReleaseMarkingRefusal(marking.refusal))

	const tag = releaseTagName(marking.kind === "mark" ? marking.release : marking.release.number)
	if (marking.kind === "mark") {
		await runCommand("git", [
			"tag",
			"--annotate",
			tag,
			"--message",
			composeReleaseAnnotation(marking.release, marking.proof),
			marking.commit,
		])
		console.log(
			`  Tag ${tag}: created on ${marking.commit.slice(0, 7)}, proven by version ${marking.proof.versionIdentifier}`,
		)
	} else {
		console.log(`  Tag ${tag}: already on HEAD`)
	}
	if (origin.releaseCommits.has(tag)) {
		console.log(`\norigin holds ${tag} already.`)
		return
	}
	console.log(
		`\n${tag} is not on origin. Push it, with the owner's go, by running:\n  git push origin refs/tags/${tag}`,
	)
}

markRelease().catch((error: unknown) => {
	if (error instanceof CommandRefused) {
		console.error(`\nRefused: ${error.message}\nNo tag was created.\nFix: ${error.remedy}`)
	} else {
		console.error(error instanceof Error ? `\n${error.message}` : error)
	}
	process.exitCode = 1
})
