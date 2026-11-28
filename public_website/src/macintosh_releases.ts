import recordedReleases from "./macintosh_releases.json" with { type: "json" }

/**
 * One release of the Mac app: its disk image on GitHub Releases and the EdDSA signature that Sparkle
 * checks against SUPublicEDKey before it installs the image. native_client/macintosh_application/
 * scripts/publish_release.sh adds each release to macintosh_releases.json, newest first.
 */
export interface MacintoshRelease {
	/** CFBundleShortVersionString, which the About panel shows. */
	version: string
	/** CFBundleVersion, which Sparkle compares to decide that a release is newer. */
	build: string
	/** RFC 3339. */
	published: string
	minimumSystemVersion: string
	diskImageUrl: string
	length: number
	edSignature: string
}

export const MACINTOSH_RELEASES: ReadonlyArray<MacintoshRelease> = recordedReleases

export const LATEST_MACINTOSH_RELEASE: MacintoshRelease | undefined = MACINTOSH_RELEASES[0]
