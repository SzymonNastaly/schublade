#!/bin/bash
# Builds the Release application signed for the team's devices and installs it on the iPhone that is
# paired with this Mac, or on the device named by its identifier.
#   native_client/iphone_application/scripts/install_application_on_device.sh [device identifier]
# Needs configuration/local_signing.xcconfig from scripts/provision_device_signing.rb.
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

if ! grep -q "PROVISIONING_PROFILE" configuration/local_signing.xcconfig 2>/dev/null; then
	echo "error: run scripts/provision_device_signing.rb first; configuration/local_signing.xcconfig names no profile." >&2
	exit 1
fi

device="${1:-}"
if [ -z "$device" ]; then
	listing="$(mktemp)"
	trap 'rm -f "$listing"' EXIT
	xcrun devicectl list devices --json-output "$listing" >/dev/null
	device="$(plutil -extract result.devices json -o - "$listing" | ruby -rjson -e '
		# A simulator states its reality as "simulated"; a paired iPhone states none.
		phone = JSON.parse(STDIN.read).find do |entry|
			entry.dig("hardwareProperties", "deviceType") == "iPhone" &&
				entry.dig("hardwareProperties", "reality") != "simulated"
		end
		puts phone ? phone["identifier"] : ""')"
fi
if [ -z "$device" ]; then
	echo "error: no iPhone is paired with this Mac. Connect it by cable once, unlock it, and trust this Mac." >&2
	exit 1
fi

xcodegen generate --quiet
xcodebuild -quiet -project Schublade.xcodeproj -scheme Schublade -configuration Release \
	-destination "generic/platform=iOS" -derivedDataPath build build
application="build/Build/Products/Release-iphoneos/Schublade.app"
codesign --verify --strict "$application"
xcrun devicectl device install app --device "$device" "$application"
