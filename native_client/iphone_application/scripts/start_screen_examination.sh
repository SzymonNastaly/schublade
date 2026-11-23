#!/bin/bash
# Prepares a simulator for an examination with AXe: builds the Debug application, starts a scripted
# archive seeded with the test documents, their first-page pictures, and their fields, and launches
# the application in the isolated environment connected to it, sending one scan of a seeded letter.
# With `empty`, the archive holds nothing and nothing is sent. With `arriving`, the scan is a
# three-page letter the archive does not hold, which stays in ingestion until a request names its
# stage, and with `refused` a text file named as a PDF is sent beside it, which the archive does not
# accept. Prints the simulator, the archive's address, and in those two the requests that move the
# scan's document on:
#   curl -X POST <archive>/scripted/documents -d '{"content_sha256": "<digest>", "status": "recognizing_text"}'
#   curl -X POST <archive>/scripted/documents -d @/tmp/schublade_iphone_screen_examination/filed.json
#   scripts/execute_on_macintosh.sh native_client/iphone_application/scripts/start_screen_examination.sh [light|dark] [seeded|empty|arriving|refused]
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
# An arriving scan is read at 40 KB a second, so its upload is under way for about 13 seconds.
pace=""
if [ "$contents" = arriving ] || [ "$contents" = refused ]; then
	pace="--ingest-pace 40000"
fi
# The server ends when its standard input closes, so a sleep holds it open for two hours.
nohup sh -c "sleep 7200 | exec ../target/debug/scripted-archive-server --token $token --permission read $pace" \
	>"$work/server.log" 2>&1 </dev/null &
for _ in $(seq 50); do
	grep -q '^listening ' "$work/server.log" 2>/dev/null && break
	sleep 0.1
done
address="$(sed -n 's/^listening //p' "$work/server.log")"

# The letter that arrives: the hardware store's receipt, with a page of the insurance policy and one
# of the tax assessment behind it, so the scan has three pages and the archive files it under the
# receipt's title.
arriving_letter="hardware_store_receipt_scanned.pdf"
scan="$work/sent/Scan 2026-11-23 09.12.pdf"
if [ "$contents" != empty ]; then
	for file in "$documents"/*.pdf "$documents"/*.jpg; do
		stem="$(basename "${file%.*}")"
		sips -s format png -Z 360 "$file" --out "$work/pictures/$stem.png" >/dev/null
	done
	if [ "$contents" = seeded ]; then
		cp "$documents/dental_invoice_scanned.pdf" "$scan"
		arriving_letter=""
	else
		# Each page is drawn at the 3,508 pixels of A4 at 300 dots per inch, as the document camera
		# writes it, so the scan weighs what a phone's does and its upload outlasts the socket buffers.
		pages=()
		for letter in "$arriving_letter" household_contents_insurance_policy_scanned.pdf income_tax_assessment_scanned.pdf; do
			sips -s format jpeg -s formatOptions 70 -Z 3508 "$documents/$letter" --out "$work/page.jpg" >/dev/null
			sips -s format pdf "$work/page.jpg" --out "$work/${letter%.pdf}_page.pdf" >/dev/null
			pages+=("$work/${letter%.pdf}_page.pdf")
		done
		"/System/Library/Automator/Combine PDF Pages.action/Contents/MacOS/join" -o "$scan" "${pages[@]}"
	fi
	if [ "$contents" = refused ]; then
		printf 'Shopping list: milk, bread, light bulbs.\n' >"$work/sent/Shopping list.pdf"
	fi
	python3 - "$address" "$documents" "$work/pictures" "$arriving_letter" "$scan" "$work/filed.json" <<'SEED'
import hashlib
import json
import re
import sys
import urllib.request
import uuid

address, documents, pictures, arriving_letter, scan, filed = sys.argv[1:]


def typed(value):
    """A catalog date is sent as a date, and any other text stays text."""
    if isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return {"date": value}
    return value


catalog = json.load(open(f"{documents}/expected_extraction.json"))
for index, document in enumerate(catalog["documents"]):
    fields = {key: typed(field["value"]) for key, field in document.get("fields", {}).items()}
    printed_amount = document.get("fields", {}).get("amount", {}).get("printed")
    summary = f"{document['category']} from {document['sender']}"
    summary += f" over {printed_amount}." if printed_amount else "."
    if "due_date" in fields:
        summary += f" Due on {fields['due_date']['date']}."
    title = document["title_hint"]
    if document["file_name"] == arriving_letter:
        digest = hashlib.sha256(open(scan, "rb").read()).hexdigest()
        classification = {
            "content_sha256": digest,
            "status": "archived",
            "title": title,
            "document_date": document.get("document_date"),
            "sender_name": document["sender"],
            "category_name": document["category"],
            "summary": summary,
            "page_count": 3,
            "text": f"# {title}\n\n{document['sender']}\n\n{summary}",
            "thumbnail_file": f"{pictures}/{arriving_letter.rsplit('.', 1)[0]}.png",
            "fields": fields,
        }
        json.dump(classification, open(filed, "w"))
        print(f"scan digest: {digest}")
        continue
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
        "page_count": document.get("page_count"),
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
