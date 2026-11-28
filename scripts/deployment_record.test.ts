import { expect, test } from "vitest"
import {
	composeVersionAnnotations,
	parseCommitIdentifier,
	parseReleaseTags,
	parseVersionRecord,
} from "./deployment_record"
import type { ReleaseNumber } from "./deployment_record"

const commit = parseCommitIdentifier("0cb2110c5a1f4e3d2b1a09f8e7d6c5b4a3928170")

test("a version's annotations record its commit and release, and only that message parses back", () => {
	const released = { commit, release: 13 as ReleaseNumber }
	const unreleased = { commit, release: undefined }
	expect({
		released: composeVersionAnnotations(released),
		unreleased: composeVersionAnnotations(unreleased),
	}).toEqual({
		released: { tag: "archive-13", message: "commit 0cb2110c5a1f4e3d2b1a09f8e7d6c5b4a3928170 release archive-13" },
		unreleased: { tag: "commit-0cb2110c5a1f", message: "commit 0cb2110c5a1f4e3d2b1a09f8e7d6c5b4a3928170" },
	})
	expect(parseVersionRecord("commit 0cb2110c5a1f4e3d2b1a09f8e7d6c5b4a3928170 release archive-13")).toEqual(released)
	expect(parseVersionRecord("commit 0cb2110c5a1f4e3d2b1a09f8e7d6c5b4a3928170")).toEqual(unreleased)
	expect(parseVersionRecord("Automatic deployment on upload.")).toBeUndefined()
	expect(parseVersionRecord(undefined)).toBeUndefined()
})

test("parseReleaseTags takes an annotated tag with its staging proof as a release and nothing else", () => {
	// What git 2.43 printed for RELEASE_TAG_LISTING_FORMAT: an annotated tag with the proof, a
	// lightweight tag, and an annotated tag without the proof.
	const listing =
		"archive-1\0tag\x00581aa4e54db7701b86ff68b18f993a9123fa53dc\0Proven-On: schublade-staging\nProven-Version: e20252fe-cc22-4429-9a3e-0ada4c7662a3\nProven-At: 2026-11-26T21:31:18.215209Z\n\0\n" +
		"archive-2\0commit\0\0\0\n" +
		"archive-3\0tag\x00581aa4e54db7701b86ff68b18f993a9123fa53dc\0\0\n"
	expect(parseReleaseTags(listing)).toEqual({
		releases: [
			{
				number: 1,
				commit: "581aa4e54db7701b86ff68b18f993a9123fa53dc",
				proof: {
					workerName: "schublade-staging",
					versionIdentifier: "e20252fe-cc22-4429-9a3e-0ada4c7662a3",
					deployedAt: "2026-11-26T21:31:18.215209Z",
				},
			},
		],
		tagsWithoutProof: ["archive-2", "archive-3"],
	})
})
