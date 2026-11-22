#!/bin/bash
# Builds InterfaceRenderer and renders every application screen in light and dark appearances.
#   native_client/macintosh_application/scripts/render_interface.sh [output_directory]
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

output_directory="${1:-build/rendered_interface}"
mkdir -p "$output_directory"

xcodegen generate --quiet
xcodebuild -quiet -project Schublade.xcodeproj -scheme Schublade -configuration Debug \
	-derivedDataPath build -destination "platform=macOS,arch=arm64" build

build/Build/Products/Debug/InterfaceRenderer \
	--output "$output_directory" \
	--fixtures "../../test_fixtures/documents"

ls -la "$output_directory"
