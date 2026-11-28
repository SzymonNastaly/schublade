/**
 * Every refusal of `pnpm run deploy` is decided here, from facts that the command read before.
 * Nothing in this file runs git or cf.
 */
import { describeVersionRecord, releaseTagName } from "./deployment_record.ts"
import type { CommitIdentifier, Release, ReleaseTags, VersionRecord } from "./deployment_record.ts"

/** How a commit relates to HEAD, or that this clone does not hold the commit. */
export type RelationToHead = "same_commit" | "ancestor" | "not_an_ancestor" | "commit_unknown"

export interface RepositoryState {
	headCommit: CommitIdentifier
	/** What `git status --porcelain` lists. Empty for a clean working tree. */
	modifiedPaths: Array<string>
	/** Whether the local branch `main` contains HEAD. */
	headOnMainBranch: boolean
	releaseTags: ReleaseTags
}

/** What only origin can say, read for an environment that admits releases only. */
export interface OriginState {
	headOnOriginMain: boolean
	/** The commit each `archive-<n>` tag on origin names. */
	releaseCommits: Map<string, CommitIdentifier>
}

/** The admission of the environment, with the facts that admission needs. */
export type AdmissionFacts = { admission: "main_branch_commits" } | { admission: "releases_only"; origin: OriginState }

export type LiveVersion = { versionIdentifier: string } & (
	{ kind: "recorded"; record: VersionRecord; relationToHead: RelationToHead } | { kind: "unrecorded" }
)

export type LiveDeployment =
	{ kind: "absent" } | { kind: "serving"; deployedAt: string; versions: [LiveVersion, ...Array<LiveVersion>] }

export interface DeploymentPlan {
	workerName: string
	/** What the new version records. It names the release whenever HEAD is one, in either admission. */
	record: VersionRecord
	replaces: LiveDeployment
}

export type DeploymentRefusal =
	| { kind: "working_tree_modified"; paths: Array<string> }
	| { kind: "commit_not_on_main_branch"; commit: CommitIdentifier; branch: "main" | "origin/main" }
	| {
			kind: "commit_not_a_release"
			commit: CommitIdentifier
			newestRelease: Release | undefined
			tagsWithoutProof: Array<string>
	  }
	| { kind: "release_not_on_origin"; release: Release }
	/** Migrations only go forward, so the Worker never moves to a commit that does not contain the live one. */
	| { kind: "live_version_not_an_ancestor"; live: VersionRecord; relation: "not_an_ancestor" | "commit_unknown" }

function releaseOnHead(repository: RepositoryState): Release | undefined {
	return repository.releaseTags.releases.find((release) => release.commit === repository.headCommit)
}

export function decideDeployment(input: {
	workerName: string
	facts: AdmissionFacts
	repository: RepositoryState
	live: LiveDeployment
}): { kind: "admitted"; plan: DeploymentPlan } | { kind: "refused"; refusal: DeploymentRefusal } {
	const { workerName, facts, repository, live } = input
	const refuse = (refusal: DeploymentRefusal) => ({ kind: "refused" as const, refusal })
	if (repository.modifiedPaths.length > 0)
		return refuse({ kind: "working_tree_modified", paths: repository.modifiedPaths })
	const release = releaseOnHead(repository)
	if (facts.admission === "main_branch_commits") {
		if (!repository.headOnMainBranch) {
			return refuse({ kind: "commit_not_on_main_branch", commit: repository.headCommit, branch: "main" })
		}
	} else {
		if (!facts.origin.headOnOriginMain) {
			return refuse({ kind: "commit_not_on_main_branch", commit: repository.headCommit, branch: "origin/main" })
		}
		if (release === undefined) {
			return refuse({
				kind: "commit_not_a_release",
				commit: repository.headCommit,
				newestRelease: repository.releaseTags.releases.at(-1),
				tagsWithoutProof: repository.releaseTags.tagsWithoutProof,
			})
		}
		if (facts.origin.releaseCommits.get(releaseTagName(release.number)) !== release.commit) {
			return refuse({ kind: "release_not_on_origin", release })
		}
	}
	if (live.kind === "serving") {
		for (const version of live.versions) {
			if (
				version.kind === "recorded" &&
				(version.relationToHead === "not_an_ancestor" || version.relationToHead === "commit_unknown")
			) {
				return refuse({ kind: "live_version_not_an_ancestor", live: version.record, relation: version.relationToHead })
			}
		}
	}
	return {
		kind: "admitted",
		plan: { workerName, record: { commit: repository.headCommit, release: release?.number }, replaces: live },
	}
}

export function describeDeploymentRefusal(refusal: DeploymentRefusal): { message: string; remedy: string } {
	switch (refusal.kind) {
		case "working_tree_modified":
			return {
				message: `The working tree differs from its commit (${refusal.paths.join(", ")}).`,
				remedy: "Commit or remove the changes, so that the Worker version names a commit that holds exactly what runs.",
			}
		case "commit_not_on_main_branch":
			return {
				message: `${refusal.branch} does not contain ${refusal.commit.slice(0, 7)}.`,
				remedy:
					refusal.branch === "main"
						? "Check out main, or merge the commit into it, and deploy from there."
						: "Push the commit to origin's main branch first, or check out a release that origin holds.",
			}
		case "commit_not_a_release":
			return {
				message: [
					`This environment admits releases only, and ${refusal.commit.slice(0, 7)} is no release.`,
					refusal.newestRelease === undefined
						? "No release exists yet."
						: `The newest release is ${releaseTagName(refusal.newestRelease.number)}.`,
					refusal.tagsWithoutProof.length === 0
						? ""
						: `The tags ${refusal.tagsWithoutProof.join(", ")} carry no proof from staging, so they are no releases.`,
				]
					.filter((sentence) => sentence.length > 0)
					.join(" "),
				remedy: "Run `git fetch --tags`, `git checkout archive-<n>`, and `pnpm install`, then deploy again.",
			}
		case "release_not_on_origin":
			return {
				message: `${releaseTagName(refusal.release.number)} is a tag of this clone that origin does not hold with the same commit.`,
				remedy: `Push the tag with \`git push origin refs/tags/${releaseTagName(refusal.release.number)}\`, or check out a release that origin holds.`,
			}
		case "live_version_not_an_ancestor":
			return {
				message:
					refusal.relation === "commit_unknown"
						? `The Worker serves ${describeVersionRecord(refusal.live)}, a commit this clone does not hold.`
						: `The Worker serves ${describeVersionRecord(refusal.live)}, which HEAD does not contain. Migrations only go forward, so a deployment never moves the Worker back.`,
				remedy:
					"Run `git fetch`, then check out a commit that contains the live one, such as the newest commit of main.",
			}
	}
}
