#!/bin/bash
# Prepares the Mac's screen for an examination with Peekaboo: builds the Debug application, starts
# the scripted archive with forty documents, and opens the application in the isolated environment,
# which never reads the Keychain or the data of an installed Schublade. Prints the archive's address.
#   scripts/execute_on_macintosh.sh native_client/macintosh_application/scripts/start_screen_examination.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

application="build/Build/Products/Debug/Schublade Development.app"
token="screen-examination-token"

(cd .. && cargo build --locked --quiet -p scripted_archive --bin scripted-archive-server)
xcodegen generate --quiet
xcodebuild -quiet -project Schublade.xcodeproj -scheme Schublade -configuration Debug \
	-derivedDataPath build -destination "platform=macOS,arch=arm64" build

pkill -f "$application/Contents/MacOS" || true
pkill -f "scripted-archive-server --token $token" || true
# Wait for the previous application to end, or the new one finds it and quits.
for _ in 1 2 3 4 5 6 7 8 9 10; do
	pgrep -f "$application/Contents/MacOS" > /dev/null || break
	sleep 1
done

# The server ends when its standard input closes, so a sleep holds it open for two hours.
log="/tmp/scripted_archive_screen_examination.log"
nohup sh -c "sleep 7200 | exec ../target/debug/scripted-archive-server --token $token --permission read --seed 40" \
	> "$log" 2>&1 < /dev/null &
sleep 2

# Launch Services, not the executable, so the application can become the active one.
open --env SCHUBLADE_APPLICATION_ENVIRONMENT=isolated "$application"
echo "archive: $(sed -n 's/^listening //p' "$log")"
echo "token: $token"
