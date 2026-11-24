#!/bin/bash
# Archives the Release application, exports it for App Store Connect signed with the team's App Store
# profiles, and uploads it to the application's record as its next build. It submits nothing for
# review and changes no metadata.
#   native_client/iphone_application/scripts/upload_application_to_app_store.sh
# Needs configuration/local_signing.xcconfig and configuration/app_store_export_options.plist from
# scripts/provision_application_signing.rb, and asc signed in with the team key.
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

application_record=6838529522
export_options=configuration/app_store_export_options.plist
if [ ! -f "$export_options" ] || ! grep -q "PROVISIONING_PROFILE" configuration/local_signing.xcconfig 2>/dev/null; then
	echo "error: run scripts/provision_application_signing.rb first; it writes $export_options and configuration/local_signing.xcconfig." >&2
	exit 1
fi

# App Store Connect refuses a build number it already holds, so the build takes the number after the
# highest one among its iPhone builds and the uploads it is still processing.
build_number="$(asc builds next-build-number --app "$application_record" --platform IOS | plutil -extract nextBuildNumber raw -o - -)"
echo "Build number: $build_number"

archive=build/Schublade.xcarchive
exported=build/app_store_export
rm -rf "$archive" "$exported"
xcodegen generate --quiet
xcodebuild -quiet -project Schublade.xcodeproj -scheme Schublade -configuration Release \
	-destination "generic/platform=iOS" -derivedDataPath build -archivePath "$archive" \
	CURRENT_PROJECT_VERSION="$build_number" archive
# The export copies with /usr/bin/rsync, which starts the `rsync` that PATH finds first as its other
# end, and Homebrew's rsync refuses the option it passes.
PATH="/usr/bin:$PATH" xcodebuild -quiet -exportArchive -archivePath "$archive" \
	-exportOptionsPlist "$export_options" -exportPath "$exported"
asc builds upload --app "$application_record" --ipa "$exported/Schublade.ipa" --verify-timeout 2m
