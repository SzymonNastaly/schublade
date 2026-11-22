#!/bin/bash
# Builds the Release application signed with Developer ID, has Apple notarize it, staples the ticket, and
# prints the path of the zip to publish. Only the Mac's build account holds the identity and the App Store
# Connect key (the devbox README, step 16), so run it through scripts/execute_on_macintosh.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! grep -q "Developer ID Application" configuration/local_signing.xcconfig 2>/dev/null; then
	echo "Error: configuration/local_signing.xcconfig does not name a Developer ID identity." >&2
	exit 1
fi

application=$(scripts/build_application.sh Release)
codesign --verify --strict --verbose=2 "$application"

archive="$PWD/build/Schublade.zip"
rm -f "$archive"
ditto -c -k --keepParent "$application" "$archive"
xcrun notarytool submit "$archive" --key "$ASC_PRIVATE_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

# The ticket goes into the bundle, so the zip is made again after stapling and opens offline too.
xcrun stapler staple "$application"
rm "$archive"
ditto -c -k --keepParent "$application" "$archive"
spctl --assess --type execute --verbose "$application"
echo "$archive"
