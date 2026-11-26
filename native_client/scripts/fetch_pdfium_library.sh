#!/bin/bash
# Downloads the PDFium build that pdfium-render 0.9.6 binds to, chromium/8125 of
# bblanchon/pdfium-binaries, for this machine, checks its SHA-256, and installs the library into
# target/pdfium of the workspace, or into the directory given as the first argument. The test of
# PdfiumDocumentReader reads it from target/pdfium, and a release of schublade-collector places it
# beside the executable. Does nothing when the library is installed already.
set -euo pipefail

workspace="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-$workspace/target/pdfium}"
release="chromium%2F8125"

case "$(uname -s)-$(uname -m)" in
	Linux-x86_64)
		platform=linux-x64 library=libpdfium.so
		digest=e1c3ce6e270cb5e0c20816b379ad9f2c1309972697c505f508de92bf5e7d6659 ;;
	Linux-aarch64)
		platform=linux-arm64 library=libpdfium.so
		digest=8b8818f2ec57d1b213d952ca6d7f0ffeca9d0110487d0e20ad83ba918bc92efa ;;
	Darwin-arm64)
		platform=mac-arm64 library=libpdfium.dylib
		digest=4939bd935ac83ddc09a3a4f038bc43a19cea1660316a3667f26cb07a070e139d ;;
	Darwin-x86_64)
		platform=mac-x64 library=libpdfium.dylib
		digest=8a5193535b80c7215d8932f6647ae5097465b6dba2811602c21e120c2af112b0 ;;
	*)
		echo "No PDFium build is pinned for $(uname -s) $(uname -m)." >&2
		exit 1 ;;
esac

if [ -f "$destination/$library" ]; then
	exit 0
fi

download="$(mktemp -d)"
trap 'rm -rf "$download"' EXIT
curl --fail --silent --show-error --location --output "$download/pdfium.tgz" \
	"https://github.com/bblanchon/pdfium-binaries/releases/download/$release/pdfium-$platform.tgz"
if command -v sha256sum > /dev/null; then
	received="$(sha256sum "$download/pdfium.tgz" | cut -d ' ' -f 1)"
else
	received="$(shasum -a 256 "$download/pdfium.tgz" | cut -d ' ' -f 1)"
fi
if [ "$received" != "$digest" ]; then
	echo "pdfium-$platform.tgz has the SHA-256 $received, not $digest." >&2
	exit 1
fi
tar -xzf "$download/pdfium.tgz" -C "$download" "lib/$library" LICENSE
mkdir -p "$destination"
cp "$download/LICENSE" "$destination/PDFIUM_LICENSE"
cp "$download/lib/$library" "$destination/$library"
echo "Installed $destination/$library"
