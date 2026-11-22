#!/bin/bash
# Runs a command in the Mac's copy of this repository, for what needs macOS: FSEvents, iCloud Drive, and app bundles.
# `Host mac` in ~/.ssh/config names the build account. On a Mac, run the command directly instead.
set -euo pipefail

if [[ $# -eq 0 ]]; then
	echo "Usage: scripts/execute_on_macintosh.sh COMMAND [ARGS...]   e.g. scripts/execute_on_macintosh.sh cargo test --manifest-path native_client/Cargo.toml" >&2
	exit 1
fi

cd "$(dirname "$0")/.."

# macOS ships an old rsync that deletes ignored files on its side, so both ends use Homebrew's.
synchronize=(rsync -a --rsync-path=/opt/homebrew/bin/rsync)

# Copies what git would track, so credentials stay here and the Mac keeps its own build output.
if ! "${synchronize[@]}" --delete --exclude .git --filter=':- .gitignore' ./ mac:schublade/; then
	echo "Error: could not copy to the Mac. It must be awake and reachable as \`ssh mac\`." >&2
	exit 1
fi

ssh mac "cd schublade && PATH=\$HOME/.cargo/bin:/opt/homebrew/bin:\$PATH $(printf '%q ' "$@")"
