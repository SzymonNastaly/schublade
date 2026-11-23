#!/bin/bash
# Prepares a simulator for an examination with AXe: builds the Debug application, starts a scripted
# archive seeded with the test documents, their first-page pictures, and their fields, and launches
# the application in the isolated environment connected to it, sending one scan. With `empty`, the
# archive holds nothing and nothing is sent. Prints the simulator and the archive's address.
#   scripts/execute_on_macintosh.sh native_client/iphone_application/scripts/start_screen_examination.sh [light|dark] [seeded|empty]
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

appearance="${1:-light}"
contents="${2:-seeded}"
token="screen-examination-token"
documents="$(cd ../../test_fixtures/documents && pwd)"
work="/tmp/schublade_iphone_screen_examination"
application="build/Build/Products/Debug-iphonesimulator/Schublade Development.app"
simulator="$(xcrun simctl list devices available | grep -m1 -E '^\s+iPhone' | grep -oE '[A-F0-9-]{36}')"

(cd .. && cargo build --locked --quiet -p scripted_archive --bin scripted-archive-server)
xcodegen generate --quiet
xcodebuild -quiet -project Schublade.xcodeproj -scheme Schublade -configuration Debug -derivedDataPath build \
	-destination "generic/platform=iOS Simulator" build

pkill -f "scripted-archive-server --token $token" || true
rm -rf "$work"
mkdir -p "$work/pictures" "$work/sent"
# The server ends when its standard input closes, so a sleep holds it open for two hours.
nohup sh -c "sleep 7200 | exec ../target/debug/scripted-archive-server --token $token --permission read" \
	>"$work/server.log" 2>&1 </dev/null &
for _ in $(seq 50); do
	grep -q '^listening ' "$work/server.log" 2>/dev/null && break
	sleep 0.1
done
address="$(sed -n 's/^listening //p' "$work/server.log")"

if [ "$contents" = seeded ]; then
	for file in "$documents"/*.pdf "$documents"/*.jpg; do
		stem="$(basename "${file%.*}")"
		sips -s format png -Z 360 "$file" --out "$work/pictures/$stem.png" >/dev/null
	done
	cp "$documents/dental_invoice_scanned.pdf" "$work/sent/Scan 2026-11-23 09.12.pdf"
	python3 - "$address" "$documents" "$work/pictures" <<'SEED'
import json
import sys
import urllib.request
import uuid

address, documents, pictures = sys.argv[1:]
catalog = json.load(open(f"{documents}/expected_extraction.json"))
for index, document in enumerate(catalog["documents"]):
    fields = {key: field["value"] for key, field in document.get("fields", {}).items()}
    printed_amount = document.get("fields", {}).get("amount", {}).get("printed")
    summary = f"{document['category']} from {document['sender']}"
    summary += f" over {printed_amount}." if printed_amount else "."
    if "due_date" in fields:
        summary += f" Due on {fields['due_date']}."
    title = document["title_hint"]
    seed = {
        "identifier": str(uuid.UUID(int=0x60000000_0000_4000_8000_000000000000 + index)),
        "title": title,
        "document_date": document.get("document_date"),
        "sender_name": document["sender"],
        "category_name": document["category"],
        "summary": summary,
        "text": f"# {title}\n\n{document['sender']}\n\n{summary}",
        "original_file": f"{documents}/{document['file_name']}",
        "thumbnail_file": f"{pictures}/{document['file_name'].rsplit('.', 1)[0]}.png",
        "fields": fields,
    }
    request = urllib.request.Request(
        f"{address}/scripted/documents",
        data=json.dumps(seed).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(request)
SEED
fi

xcrun simctl bootstatus "$simulator" -b >/dev/null
xcrun simctl ui "$simulator" appearance "$appearance"
xcrun simctl status_bar "$simulator" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4
xcrun simctl terminate "$simulator" org.schublade.iphone.development 2>/dev/null || true
xcrun simctl install "$simulator" "$application"
SIMCTL_CHILD_SCHUBLADE_APPLICATION_ENVIRONMENT=isolated \
	SIMCTL_CHILD_SCHUBLADE_EXAMINATION_ARCHIVE="$address" \
	SIMCTL_CHILD_SCHUBLADE_EXAMINATION_TOKEN="$token" \
	SIMCTL_CHILD_SCHUBLADE_EXAMINATION_DOCUMENTS="$work/sent" \
	xcrun simctl launch "$simulator" org.schublade.iphone.development >/dev/null
echo "simulator: $simulator"
echo "archive: $address"
