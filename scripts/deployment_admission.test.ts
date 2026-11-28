import { expect, test } from "vitest"
import { decideDeployment } from "./deployment_admission"
import { parseCommitIdentifier } from "./deployment_record"
import type { AdmissionFacts, LiveDeployment, RepositoryState } from "./deployment_admission"
import type { Release, ReleaseNumber } from "./deployment_record"

const headCommit = parseCommitIdentifier("0cb2110c5a1f4e3d2b1a09f8e7d6c5b4a3928170")
const earlierCommit = parseCommitIdentifier("59f413c0a1b2c3d4e5f60718293a4b5c6d7e8f90")
const releaseOfHead: Release = {
	number: 13 as ReleaseNumber,
	commit: headCommit,
	proof: {
		workerName: "schublade-staging",
		versionIdentifier: "e20252fe-cc22-4429-9a3e-0ada4c7662a3",
		deployedAt: "2026-11-28T09:14:02Z",
	},
}
const earlierRelease: Release = { ...releaseOfHead, number: 12 as ReleaseNumber, commit: earlierCommit }

const cleanCheckout: RepositoryState = {
	headCommit,
	modifiedPaths: [],
	headOnMainBranch: true,
	releaseTags: { releases: [earlierRelease], tagsWithoutProof: [] },
}
const mainBranchCommits: AdmissionFacts = { admission: "main_branch_commits" }
const absent: LiveDeployment = { kind: "absent" }

function decide(facts: AdmissionFacts, repository: RepositoryState, live: LiveDeployment = absent) {
	return decideDeployment({ workerName: "schublade-staging", facts, repository, live })
}

test("a modified working tree is refused with its paths", () => {
	expect(decide(mainBranchCommits, { ...cleanCheckout, modifiedPaths: ["src/server.ts"] })).toEqual({
		kind: "refused",
		refusal: { kind: "working_tree_modified", paths: ["src/server.ts"] },
	})
})

test("main_branch_commits admits a commit of the local main branch and records its release when it is one", () => {
	expect(decide(mainBranchCommits, { ...cleanCheckout, headOnMainBranch: false })).toEqual({
		kind: "refused",
		refusal: { kind: "commit_not_on_main_branch", commit: headCommit, branch: "main" },
	})
	const released = {
		...cleanCheckout,
		releaseTags: { releases: [earlierRelease, releaseOfHead], tagsWithoutProof: [] },
	}
	expect(decide(mainBranchCommits, released)).toEqual({
		kind: "admitted",
		plan: { workerName: "schublade-staging", record: { commit: headCommit, release: 13 }, replaces: absent },
	})
})

test("releases_only admits only a release whose tag origin holds on its main branch", () => {
	const onOrigin = (releaseCommits: Map<string, typeof headCommit>): AdmissionFacts => ({
		admission: "releases_only",
		origin: { headOnOriginMain: true, releaseCommits },
	})
	const handTagged = {
		...cleanCheckout,
		headOnMainBranch: false,
		releaseTags: { releases: [earlierRelease], tagsWithoutProof: ["archive-13"] },
	}
	expect(
		decide({ admission: "releases_only", origin: { headOnOriginMain: false, releaseCommits: new Map() } }, handTagged),
	).toEqual({
		kind: "refused",
		refusal: { kind: "commit_not_on_main_branch", commit: headCommit, branch: "origin/main" },
	})
	expect(decide(onOrigin(new Map()), handTagged)).toEqual({
		kind: "refused",
		refusal: {
			kind: "commit_not_a_release",
			commit: headCommit,
			newestRelease: earlierRelease,
			tagsWithoutProof: ["archive-13"],
		},
	})
	const released = { ...handTagged, releaseTags: { releases: [earlierRelease, releaseOfHead], tagsWithoutProof: [] } }
	expect(decide(onOrigin(new Map([["archive-12", earlierCommit]])), released)).toEqual({
		kind: "refused",
		refusal: { kind: "release_not_on_origin", release: releaseOfHead },
	})
	expect(decide(onOrigin(new Map([["archive-13", headCommit]])), released)).toEqual({
		kind: "admitted",
		plan: { workerName: "schublade-staging", record: { commit: headCommit, release: 13 }, replaces: absent },
	})
})

test("a live version that HEAD does not contain is refused, and an unrecorded one is replaced", () => {
	const serving = (relationToHead: "ancestor" | "not_an_ancestor"): LiveDeployment => ({
		kind: "serving",
		deployedAt: "2026-11-28T09:14:02Z",
		versions: [
			{
				versionIdentifier: "e20252fe",
				kind: "recorded",
				record: { commit: earlierCommit, release: 12 as ReleaseNumber },
				relationToHead,
			},
			{ versionIdentifier: "7a1b9e20", kind: "unrecorded" },
		],
	})
	expect(decide(mainBranchCommits, cleanCheckout, serving("not_an_ancestor"))).toEqual({
		kind: "refused",
		refusal: {
			kind: "live_version_not_an_ancestor",
			live: { commit: earlierCommit, release: 12 },
			relation: "not_an_ancestor",
		},
	})
	expect(decide(mainBranchCommits, cleanCheckout, serving("ancestor")).kind).toBe("admitted")
})
