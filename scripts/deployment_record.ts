/**
 * The two records of what an environment runs, each with its one written format and its parser:
 *
 *   1. On a Worker version: the commit, and the release if any, that the version was built from,
 *      written with `cf deploy --tag <tag> --message <message>` and read back from the version's
 *      `annotations`.
 *   2. On an annotated git tag `archive-<n>`: that a commit is release n, and which staging
 *      version served it when the release was marked. The proof travels with the tag, so an
 *      installation without staging checks it with git alone.
 */

declare const commitIdentifierBrand: unique symbol
/** 40 lowercase hexadecimal digits, as `git rev-parse HEAD` prints them. */
export type CommitIdentifier = string & { readonly [commitIdentifierBrand]: true }

export function parseCommitIdentifier(text: string): CommitIdentifier {
	const trimmed = text.trim()
	if (!/^[0-9a-f]{40}$/.test(trimmed)) throw new Error(`Not a commit identifier: ${JSON.stringify(text)}`)
	return trimmed as CommitIdentifier
}

declare const releaseNumberBrand: unique symbol
/** A positive integer. Release n + 1 follows release n, and no number is reused. */
export type ReleaseNumber = number & { readonly [releaseNumberBrand]: true }

const releaseTagPattern = /^archive-([1-9][0-9]*)$/

export function releaseTagName(release: ReleaseNumber): string {
	return `archive-${release}`
}

function parseReleaseTagName(name: string): ReleaseNumber | undefined {
	const digits = releaseTagPattern.exec(name)?.[1]
	return digits === undefined ? undefined : (Number(digits) as ReleaseNumber)
}

export interface VersionRecord {
	commit: CommitIdentifier
	release: ReleaseNumber | undefined
}

/**
 * The message is the record and the only part that is parsed. The tag repeats it for a person who
 * reads the dashboard. Both stay short: a message of at most 64 characters and a tag of at most 19.
 */
export function composeVersionAnnotations(record: VersionRecord): { tag: string; message: string } {
	if (record.release === undefined) {
		return { tag: `commit-${record.commit.slice(0, 12)}`, message: `commit ${record.commit}` }
	}
	const tag = releaseTagName(record.release)
	return { tag, message: `commit ${record.commit} release ${tag}` }
}

const versionMessagePattern = /^commit ([0-9a-f]{40})(?: release (archive-[1-9][0-9]*))?$/

/** Undefined for a version that a bare `cf deploy` uploaded, whose message is absent or cf's own. */
export function parseVersionRecord(message: string | undefined): VersionRecord | undefined {
	const match = versionMessagePattern.exec(message ?? "")
	if (match?.[1] === undefined) return undefined
	return {
		commit: parseCommitIdentifier(match[1]),
		release: match[2] === undefined ? undefined : parseReleaseTagName(match[2]),
	}
}

export function describeVersionRecord(record: VersionRecord): string {
	const commit = record.commit.slice(0, 7)
	return record.release === undefined ? commit : `${releaseTagName(record.release)} (${commit})`
}

/** The staging version that served the release's commit when the release was marked. */
export interface StagingProof {
	workerName: string
	versionIdentifier: string
	/** The `created_on` of the staging deployment, in ISO 8601. */
	deployedAt: string
}

export interface Release {
	number: ReleaseNumber
	commit: CommitIdentifier
	proof: StagingProof
}

/**
 * The message of the annotated tag. git reads its last paragraph as trailers, which
 * RELEASE_TAG_LISTING_FORMAT lists and parseReleaseTags reads back.
 */
export function composeReleaseAnnotation(release: ReleaseNumber, proof: StagingProof): string {
	return [
		`Schublade archive release ${release}`,
		"",
		`Proven-On: ${proof.workerName}`,
		`Proven-Version: ${proof.versionIdentifier}`,
		`Proven-At: ${proof.deployedAt}`,
	].join("\n")
}

/**
 * The `--format` of `git for-each-ref 'refs/tags/archive-*'` that parseReleaseTags reads: the tag
 * name, its object type, the commit an annotated tag points at, and its trailers, each followed by
 * NUL. git ends every reference with a newline after the last NUL.
 */
export const RELEASE_TAG_LISTING_FORMAT =
	"%(refname:strip=2)%00%(objecttype)%00%(*objectname)%00%(contents:trailers:only,unfold)%00"

export interface ReleaseTags {
	/** Ascending by number. */
	releases: Array<Release>
	/** Tags named `archive-<n>` that are lightweight or lack the proof: made by hand, and no releases. */
	tagsWithoutProof: Array<string>
}

const proofTrailerPattern = /^Proven-(On|Version|At): (.+)$/gm

export function parseReleaseTags(listing: string): ReleaseTags {
	const releases: Array<Release> = []
	const tagsWithoutProof: Array<string> = []
	for (const entry of listing.split("\0\n").filter((text) => text.length > 0)) {
		const [name = "", objectType, taggedCommit = "", trailers = ""] = entry.split("\0")
		const number = parseReleaseTagName(name)
		if (number === undefined) continue
		const proof = new Map([...trailers.matchAll(proofTrailerPattern)].map((match) => [match[1], match[2]]))
		const [workerName, versionIdentifier, deployedAt] = [proof.get("On"), proof.get("Version"), proof.get("At")]
		if (
			objectType !== "tag" ||
			workerName === undefined ||
			versionIdentifier === undefined ||
			deployedAt === undefined
		) {
			tagsWithoutProof.push(name)
			continue
		}
		releases.push({
			number,
			commit: parseCommitIdentifier(taggedCommit),
			proof: { workerName, versionIdentifier, deployedAt },
		})
	}
	releases.sort((left, right) => left.number - right.number)
	return { releases, tagsWithoutProof }
}

/** One above every number that a tag here or on origin uses, releases and hand-made tags alike. */
export function nextReleaseNumber(tagNames: Array<string>): ReleaseNumber {
	const numbers = tagNames.map(parseReleaseTagName).filter((number) => number !== undefined)
	return (Math.max(0, ...numbers) + 1) as ReleaseNumber
}

/** The commit each `archive-<n>` tag on a remote names, from `git ls-remote --tags <remote>`. */
export function parseRemoteReleaseCommits(listing: string): Map<string, CommitIdentifier> {
	const direct = new Map<string, CommitIdentifier>()
	const peeled = new Map<string, CommitIdentifier>()
	for (const line of listing.split("\n").filter((text) => text.length > 0)) {
		const [objectName = "", reference = ""] = line.split("\t")
		const name = reference.replace(/^refs\/tags\//, "")
		if (name.endsWith("^{}")) peeled.set(name.slice(0, -3), parseCommitIdentifier(objectName))
		else direct.set(name, parseCommitIdentifier(objectName))
	}
	return new Map([...direct, ...peeled])
}
