#!/bin/bash
# Downloads the Sparkle release whose framework project.yml links, checks its SHA-256, and unpacks its
# command-line tools into build/sparkle_tools: generate_keys, which made the update signing key in the
# build account's login Keychain once and exported it to ~/.config/schublade/sparkle_update_key, and
# sign_update, which signs each release's disk image with that file.
# The version and digest change together with the package version in project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

version="2.10.1"
digest="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
tools="$PWD/build/sparkle_tools"

if [ -x "$tools/bin/sign_update" ] && [ "$(cat "$tools/version" 2>/dev/null)" = "$version" ]; then
	echo "$tools/bin"
	exit 0
fi
archive="$(mktemp -d)/Sparkle-$version.tar.xz"
curl --fail --silent --show-error --location --output "$archive" \
	"https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
echo "$digest  $archive" | shasum -a 256 --check --status
rm -rf "$tools"
mkdir -p "$tools"
tar -xJf "$archive" -C "$tools" ./bin
echo "$version" >"$tools/version"
echo "$tools/bin"
