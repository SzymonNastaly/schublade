#!/bin/bash
# Draws application/AppIcon.icon as people see it, for review: through Icon Composer's renderer at
# 16, 32, 128, and 512 points in each appearance of macOS 26, and as the flattened icon the asset
# catalogue compiler writes for macOS 14 and 15. The compiler builds the bundle's icon from the
# same document on its own, so nothing here is committed.
#   native_client/macintosh_application/scripts/render_application_icon.sh [output_directory]
set -euo pipefail
cd "$(dirname "$0")/.."

output_directory="${1:-build/rendered_icon}"
rm -rf "$output_directory"
mkdir -p "$output_directory"
icon_tool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"

for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
	for points in 16 32 128 512; do
		"$icon_tool" application/AppIcon.icon --export-image --platform macOS --rendition "$rendition" \
			--width "$points" --height "$points" --scale 2 \
			--output-file "$output_directory/icon_${rendition}_${points}pt.png"
	done
done

compiled="$(mktemp -d)"
trap 'rm -rf "$compiled"' EXIT
xcrun actool --compile "$compiled" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
	--output-partial-info-plist "$compiled/partial.plist" --errors application/AppIcon.icon >/dev/null
iconutil --convert iconset "$compiled/AppIcon.icns" --output "$output_directory/flattened.iconset"
ls -la "$output_directory" "$output_directory/flattened.iconset"
