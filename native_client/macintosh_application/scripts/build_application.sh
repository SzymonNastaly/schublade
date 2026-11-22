#!/bin/bash
# Builds the application in the given configuration and prints the path of its bundle.
#   native_client/macintosh_application/scripts/build_application.sh [Debug|Release]
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

configuration="${1:-Debug}"
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -quiet -project Schublade.xcodeproj -scheme Schublade -configuration "$configuration" \
	-derivedDataPath build -destination "platform=macOS,arch=arm64" build
find "$PWD/build/Build/Products/$configuration" -maxdepth 1 -name "*.app"
