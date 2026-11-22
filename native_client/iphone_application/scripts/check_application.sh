#!/bin/bash
# The one check of the iPhone application: the cargo checks of the iPhone's targets, SwiftFormat,
# SwiftLint, the Release build for the device, and the end-to-end test in the Debug build on the
# simulator against a scripted archive that runs on the Mac.
#   native_client/iphone_application/scripts/check_application.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

(cd .. && cargo clippy --locked --target aarch64-apple-ios-sim -p archive_access -p application_bindings -- -D warnings \
	&& cargo build --locked -p scripted_archive --bin scripted-archive-server)

swiftformat --lint --quiet .
swiftlint lint --strict --quiet
interface_builder_files="$(find . -path ./build -prune -o \( -name "*.xib" -o -name "*.storyboard" \) -print)"
if [ -n "$interface_builder_files" ]; then
	echo "error: the interface is built in code, so no Interface Builder file belongs here:" >&2
	echo "$interface_builder_files" >&2
	exit 1
fi

xcodegen generate --quiet
project=(-project Schublade.xcodeproj -scheme Schublade -derivedDataPath build)
xcodebuild -quiet "${project[@]}" -configuration Release -destination "generic/platform=iOS" \
	CODE_SIGNING_ALLOWED=NO build

# The scripted archive ends when its standard input closes, so a pipe held open by this script
# keeps it for the test and ends it with the script.
work="$(mktemp -d)"
trap 'exec 3>&- 2>/dev/null || true; rm -rf "$work"' EXIT
mkfifo "$work/input"
../target/debug/scripted-archive-server --token scripted-end-to-end-token --permission read --seed 5 \
	<"$work/input" >"$work/output" &
exec 3>"$work/input"
for _ in $(seq 50); do
	grep -q '^listening ' "$work/output" 2>/dev/null && break
	sleep 0.1
done
address="$(sed -n 's/^listening //p' "$work/output")"
if [ -z "$address" ]; then
	echo "error: scripted-archive-server did not start" >&2
	exit 1
fi

simulator="$(xcrun simctl list devices available | grep -m1 -E '^\s+iPhone' | grep -oE '[A-F0-9-]{36}')"
# A simulator that xcodebuild boots itself can refuse the launch while SpringBoard still starts
# ("Busy", "Application failed preflight checks"), so the script boots it and waits until it is
# ready, and shuts it down again at the end.
xcrun simctl bootstatus "$simulator" -b >/dev/null
trap 'exec 3>&- 2>/dev/null || true; rm -rf "$work"; xcrun simctl shutdown "$simulator" 2>/dev/null || true' EXIT
# The full log stays in build/, and the filter shows the test's own result lines and every
# diagnostic. A failure that happens before any test runs shows the log's last lines as well.
log=build/end_to_end_test.log
status=0
TEST_RUNNER_SCHUBLADE_SCRIPTED_ARCHIVE="$address" \
	xcodebuild "${project[@]}" -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
	-test-timeouts-enabled YES -default-test-execution-time-allowance 120 test >"$log" 2>&1 || status=$?
grep -E "^(/.*: (error|warning)|error|warning|ld: |Test Case|[[:space:]]+Executed|\*\* TEST|Test run|Suite |Test |✔|✘)" "$log" || true
if [ "$status" -ne 0 ]; then
	echo "error: the end-to-end test failed; the last lines of $log:" >&2
	grep -v "^ *export " "$log" | tail -25 >&2
	exit "$status"
fi
