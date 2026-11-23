#!/bin/bash
# Renders the drawings of the icon into the asset catalogue: application/application_icon.svg as the
# Home Screen icon and as ApplicationIconPicture, the picture the welcome screen and Settings show,
# and application_icon_dark.svg and application_icon_tinted.svg, where they exist, as the icon's dark
# and tinted variants. Quick Look draws each SVG, and the alpha channel goes, because the system
# refuses an icon that has one. Writes into the Mac's copy, so fetch the files afterwards:
#   scripts/execute_on_macintosh.sh native_client/iphone_application/scripts/render_application_icon.sh
#   scp 'mac:schublade/native_client/iphone_application/application/Assets.xcassets/{AppIcon.appiconset,ApplicationIconPicture.imageset}/*.png' ...
set -euo pipefail
cd "$(dirname "$0")/../application"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat >"$work/flatten.swift" <<'FLATTEN'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// flatten <source.png> <destination.png> <side in pixels>: the picture drawn opaque at that size.
let arguments = CommandLine.arguments
guard arguments.count == 4, let side = Int(arguments[3]),
      let source = CGImageSourceCreateWithURL(URL(filePath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
      	data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      	bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ),
      let destination = CGImageDestinationCreateWithURL(
      	URL(filePath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil
      )
else {
	FileHandle.standardError.write(Data("usage: flatten <source.png> <destination.png> <side>\n".utf8))
	exit(1)
}
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
guard let flattened = context.makeImage() else {
	exit(1)
}
CGImageDestinationAddImage(destination, flattened, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
FLATTEN
xcrun swiftc -O -o "$work/flatten" "$work/flatten.swift"

render() {
	local drawing="$1" destination="$2" side="$3"
	qlmanage -t -s 1024 -o "$work" "$drawing" >/dev/null 2>&1
	"$work/flatten" "$work/$(basename "$drawing").png" "$destination" "$side"
}

icon=Assets.xcassets/AppIcon.appiconset
picture=Assets.xcassets/ApplicationIconPicture.imageset
render application_icon.svg "$icon/application_icon.png" 1024
# The welcome screen shows the picture at 88 points.
render application_icon.svg "$picture/application_icon_picture@2x.png" 176
render application_icon.svg "$picture/application_icon_picture@3x.png" 264
for variant in dark tinted; do
	if [ -f "application_icon_$variant.svg" ]; then
		render "application_icon_$variant.svg" "$icon/application_icon_$variant.png" 1024
	fi
done
