#!/bin/bash
# Publishes the Mac application: runs release_application.sh on the Mac, uploads its disk image to a
# GitHub release tagged mac-<version>, records the release in public_website/src/macintosh_releases.json,
# and deploys the website, whose /mac/appcast.xml every installed copy reads and whose Mac page links
# the newest image. Run it on the server, where gh is signed in, after MARKETING_VERSION and
# CURRENT_PROJECT_VERSION in project.yml were raised and the commit was pushed. Commit and push the
# record it writes afterwards.
#   native_client/macintosh_application/scripts/publish_release.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
releases="public_website/src/macintosh_releases.json"

if ! git diff --quiet HEAD -- native_client; then
	echo "Error: native_client has changes; the Mac builds what git tracks, so commit them first." >&2
	exit 1
fi
git fetch --quiet origin main
if ! git merge-base --is-ancestor HEAD origin/main; then
	echo "Error: push the commit first, so the release's tag names a commit GitHub holds." >&2
	exit 1
fi

values=$(scripts/execute_on_macintosh.sh native_client/macintosh_application/scripts/release_application.sh | tail -6)
value() {
	echo "$values" | sed -n "s/^$1=//p"
}
version=$(value version)
build=$(value build)
disk_image=$(value disk_image)
for name in version build minimum_system_version disk_image signature length; do
	if [ -z "$(value $name)" ]; then
		echo "Error: release_application.sh named no $name." >&2
		exit 1
	fi
done
if node -e 'const [file, build] = process.argv.slice(1); const releases = require(file); process.exit(releases.some((release) => Number(release.build) >= Number(build)) ? 0 : 1)' "$root/$releases" "$build"; then
	echo "Error: build $build is not above every recorded release, so Sparkle would offer it to no one." >&2
	exit 1
fi

tag="mac-$version"
file_name="Schublade-$version.dmg"
work=$(mktemp -d)
scp -q "mac:$disk_image" "$work/$file_name"
gh release create "$tag" "$work/$file_name" --target "$(git rev-parse HEAD)" --title "Schublade for Mac $version" \
	--notes "Schublade for Mac $version ($build), signed with Developer ID and notarized. Installed copies update themselves; to install, open the disk image and drag Schublade to Applications."
repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

node -e '
const { readFileSync, writeFileSync } = require("node:fs")
const [file, version, build, minimumSystemVersion, diskImageUrl, length, edSignature] = process.argv.slice(1)
const releases = JSON.parse(readFileSync(file, "utf8"))
const release = { version, build, published: new Date().toISOString(), minimumSystemVersion, diskImageUrl, length: Number(length), edSignature }
writeFileSync(file, JSON.stringify([release, ...releases], null, "\t") + "\n")
' "$root/$releases" "$version" "$build" "$(value minimum_system_version)" \
	"https://github.com/$repository/releases/download/$tag/$file_name" "$(value length)" "$(value signature)"

pnpm --dir public_website run deploy
echo "Published $tag and deployed the website; commit and push $releases."
