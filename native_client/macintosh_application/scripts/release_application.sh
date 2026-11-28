#!/bin/bash
# Builds the Release application signed with Developer ID, has Apple notarize it, and packs it into a
# disk image that is signed, notarized, and stapled too. Sparkle's sign_update then signs the image
# with the update key in ~/.config/schublade/sparkle_update_key, a file only the build account reads:
# macOS refuses sign_update the copy in the login Keychain over SSH, because generate_keys made it.
# Only that account holds the identity, the App Store Connect key, and the update key (the devbox
# README, step 16), so run it through scripts/execute_on_macintosh.sh. The last six lines name the
# version, the build, the oldest macOS it runs on, the image, its EdDSA signature, and its length,
# which scripts/publish_release.sh reads.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! grep -q "Developer ID Application" configuration/local_signing.xcconfig 2>/dev/null; then
	echo "Error: configuration/local_signing.xcconfig does not name a Developer ID identity." >&2
	exit 1
fi
identity="Developer ID Application"
update_key="$HOME/.config/schublade/sparkle_update_key"
if [ ! -r "$update_key" ]; then
	echo "Error: $update_key is missing; export it with generate_keys -x from the login Keychain." >&2
	exit 1
fi
sparkle_tools=$(scripts/fetch_sparkle_tools.sh)

notarize() {
	xcrun notarytool submit "$1" --key "$ASC_PRIVATE_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
		--wait --output-format json | tee /dev/stderr | plutil -extract status raw - | grep -qx Accepted
}

application=$(scripts/build_application.sh Release 2>&1 | tail -1)

# Xcode signs Sparkle.framework when it embeds it, but not the helpers inside it, which keep Sparkle's
# ad hoc signatures, and the notary service refuses those. Sparkle's documentation signs them from the
# inside out, then the framework, then the application.
framework="$application/Contents/Frameworks/Sparkle.framework"
sign() {
	codesign --force --sign "$identity" --options runtime --timestamp "$@"
}
sign "$framework/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
sign "$framework/Versions/B/Autoupdate"
sign "$framework/Versions/B/Updater.app"
sign "$framework"
sign "$application"
codesign --verify --deep --strict --verbose=2 "$application"

work="$PWD/build/release"
rm -rf "$work"
mkdir -p "$work"
ditto -c -k --keepParent "$application" "$work/Schublade.zip"
notarize "$work/Schublade.zip"
xcrun stapler staple "$application"
spctl --assess --type execute --verbose "$application"

version=$(plutil -extract CFBundleShortVersionString raw "$application/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$application/Contents/Info.plist")
contents="$work/disk_image_contents"
mkdir -p "$contents"
ditto "$application" "$contents/Schublade.app"
ln -s /Applications "$contents/Applications"
image="$work/Schublade-$version.dmg"
hdiutil create -volname "Schublade $version" -srcfolder "$contents" -fs APFS -format ULFO -ov "$image" >/dev/null
codesign --force --sign "$identity" --timestamp "$image"
notarize "$image"
xcrun stapler staple "$image"
spctl --assess --type open --context context:primary-signature --verbose "$image"

signature=$("$sparkle_tools/sign_update" -p --ed-key-file "$update_key" "$image")
echo "version=$version"
echo "build=$build"
echo "minimum_system_version=$(plutil -extract LSMinimumSystemVersion raw "$application/Contents/Info.plist")"
echo "disk_image=$image"
echo "signature=$signature"
echo "length=$(stat -f %z "$image")"
