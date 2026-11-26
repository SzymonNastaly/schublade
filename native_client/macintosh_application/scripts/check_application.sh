#!/bin/bash
# The one check of the Mac application: the PDFium library the program's test reads, the
# workspace's cargo checks, SwiftFormat, SwiftLint, the build of every target in both
# configurations, and both the presentation and end-to-end tests.
#   native_client/macintosh_application/scripts/check_application.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

(cd .. && scripts/fetch_pdfium_library.sh \
	&& cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked \
	&& cargo build --locked -p scripted_archive --bin scripted-archive-server)

# The shared library sources sit beside this directory, so the configuration is named.
swiftformat --lint --quiet --config .swiftformat . ../library_presentation ../library_presentation_tests
swiftlint lint --strict --quiet
interface_builder_files="$(find . -path ./build -prune -o \( -name "*.xib" -o -name "*.storyboard" \) -print)"
if [ -n "$interface_builder_files" ]; then
	echo "error: the interface is built in code, so no Interface Builder file belongs here:" >&2
	echo "$interface_builder_files" >&2
	exit 1
fi

xcodegen generate --quiet
project=(-project Schublade.xcodeproj -scheme Schublade -derivedDataPath build
	-destination "platform=macOS,arch=arm64")
xcodebuild -quiet "${project[@]}" -configuration Release build
# Launch Services starts one copy of an application, so a Debug copy left from a screen examination
# would keep the test's copy from starting. The installed Release application is another bundle.
pkill -f "Schublade Development.app/Contents/MacOS" || true
# Not quiet, so that the test's own result lines show. The filter keeps every diagnostic.
xcodebuild "${project[@]}" -configuration Debug test 2>&1 |
	grep -E "^(/.*: (error|warning)|error|warning|ld: |Test Case|[[:space:]]+Executed|\*\* TEST|Test run|Suite |Test |✔|✘)"
