#!/bin/bash
# Captures the App Store screenshots of the iPhone application on a 6.9-inch simulator of its own, in
# light and dark, and writes them to build/store_screenshots/<appearance>/NN_<scene>.png on the Mac.
# The archive is the scripted one seeded with the test documents, with a three-page scan arriving
# that the archive holds at "Recognizing text". Each scene starts and ends on the library at All
# Documents; a scene is one function and one line of the table below. Prints the directory.
#   scripts/execute_on_macintosh.sh native_client/iphone_application/scripts/capture_store_screenshots.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
cd "$(dirname "$0")/.."

# App Store Connect requires the 6.9-inch size, 1320 by 2868 pixels in portrait.
simulator_name="Schublade Store Screenshots"
simulator_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
screen_width=1320
screen_height=2868
token="store-screenshot-token"
work="/tmp/schublade_store_screenshots"
output="$PWD/build/store_screenshots"
nordkabel_invoice="document.60000000-0000-4000-8000-000000000000"
software_invoice="document.60000000-0000-4000-8000-00000000000a"

scenes=(
	"01_library_arriving scene_library_arriving"
	"02_search_scope scene_search_scope"
	"03_document_original scene_document_original"
	"04_document_details scene_document_details"
	"05_context_menu_preview scene_context_menu_preview"
	"06_share_sheet scene_share_sheet"
)

simulator=""
appearance=""

stop_session() {
	# The archive runs as `sleep | scripted-archive-server` under one shell, so its children end with it.
	for shell in $(pgrep -f "exec ../target/debug/scripted-archive-server --token $token" || true); do
		pkill -P "$shell" || true
		kill "$shell" 2>/dev/null || true
	done
	if [ -n "$simulator" ]; then
		xcrun simctl shutdown "$simulator" 2>/dev/null || true
	fi
}
trap stop_session EXIT

# Fails after the given seconds unless the accessibility tree holds the text.
await_text() {
	local text="$1" seconds="$2"
	for _ in $(seq "$seconds"); do
		# Read whole, because grep -q ending the pipe early fails it under pipefail.
		[[ "$(axe describe-ui --udid "$simulator")" == *"$text"* ]] && return 0
		sleep 1
	done
	mkdir -p "$output"
	xcrun simctl io "$simulator" screenshot "$output/failure.png" >/dev/null 2>&1
	echo "error: \"$text\" did not appear within $seconds seconds in the $appearance scenes;" \
		"the screen is in $output/failure.png" >&2
	return 1
}

# Fails after the given seconds unless the text has left the accessibility tree.
await_text_gone() {
	local text="$1" seconds="$2"
	for _ in $(seq "$seconds"); do
		[[ "$(axe describe-ui --udid "$simulator")" != *"$text"* ]] && return 0
		sleep 1
	done
	echo "error: \"$text\" did not leave the screen within $seconds seconds in the $appearance scenes" >&2
	return 1
}

# Keeps the screen once two screenshots a second apart are identical, so no animation is caught
# half-way and no picture is caught loading.
capture() {
	local file="$output/$appearance/$1.png" previous="$work/previous_screen.png"
	xcrun simctl io "$simulator" screenshot "$previous" >/dev/null 2>&1
	for attempt in $(seq 15); do
		sleep 1
		xcrun simctl io "$simulator" screenshot "$file" >/dev/null 2>&1
		cmp -s "$previous" "$file" && break
		if [ "$attempt" -eq 15 ]; then
			echo "error: the screen of $1 in $appearance did not settle within 15 seconds" >&2
			return 1
		fi
		mv "$file" "$previous"
	done
	local size
	size="$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ { print $2 }' | paste -sd x -)"
	if [ "$size" != "${screen_width}x${screen_height}" ]; then
		echo "error: $file is $size pixels, not ${screen_width}x${screen_height}" >&2
		return 1
	fi
}

return_to_library() {
	await_text '"AXLabel" : "All Documents"' 10
	sleep 1
}

# Opens a document's page and waits for its original. The page presents the details sheet if it
# showed when the last page closed, a moment after the original.
open_document() {
	axe tap --id "$1" --wait-timeout 10 --udid "$simulator" >/dev/null
	await_text '"AXUniqueId" : "document.original.pdf"' 10
	await_text 'Ihre Rechnung' 20
	sleep 2
}

details_sheet_shown() {
	[[ "$(axe describe-ui --udid "$simulator")" == *'"AXUniqueId" : "document.details.hide"'* ]]
}

scene_library_arriving() {
	# The list moves a little when the arriving row first shows. A short drag returns it to the top,
	# below the distance that refreshes.
	axe swipe --start-x 220 --start-y 400 --end-x 220 --end-y 450 --duration 0.5 --delta 10 --udid "$simulator" >/dev/null
	capture "$1"
}

scene_search_scope() {
	axe tap --label Search --wait-timeout 10 --udid "$simulator" >/dev/null
	sleep 1
	axe type invoice --udid "$simulator"
	axe tap --id library.suggestion --wait-timeout 10 --udid "$simulator" >/dev/null
	# Return ends the editing, so no caret blinks beside the scope's token.
	axe key 40 --udid "$simulator" >/dev/null
	await_text '"AXLabel" : "3 documents"' 10
	capture "$1"
	axe tap --label "Clear text" --udid "$simulator" >/dev/null
	sleep 0.5
	axe tap --label close --udid "$simulator" >/dev/null
	return_to_library
}

scene_document_original() {
	open_document "$nordkabel_invoice"
	if details_sheet_shown; then
		axe tap --id document.details.hide --udid "$simulator" >/dev/null
		await_text_gone '"AXUniqueId" : "document.details.hide"' 10
	fi
	capture "$1"
	axe tap --id BackButton --udid "$simulator" >/dev/null
	return_to_library
}

scene_document_details() {
	open_document "$nordkabel_invoice"
	if ! details_sheet_shown; then
		axe tap --id document.details.show --udid "$simulator" >/dev/null
		await_text '"AXUniqueId" : "document.details.hide"' 10
	fi
	capture "$1"
	axe tap --id BackButton --udid "$simulator" >/dev/null
	return_to_library
}

scene_context_menu_preview() {
	axe tap --id "$software_invoice" --hold 1.2 --wait-timeout 10 --udid "$simulator" >/dev/null
	await_text '"AXLabel" : "Open in Browser"' 10
	# The preview shows the row's picture at once and the first page once the original is drawn.
	sleep 3
	capture "$1"
	axe tap -x 100 -y 90 --udid "$simulator" >/dev/null
	return_to_library
}

scene_share_sheet() {
	echo "skipped $1: the share extension reads the connected archive from the App Group, which the" \
		"isolated examination launch never writes, so its sheet offers no archive to send to"
}

simulator="$(xcrun simctl list devices | grep -F "    $simulator_name (" | grep -oE '[A-F0-9-]{36}' | head -1 || true)"
if [ -z "$simulator" ]; then
	runtime="$(xcrun simctl list runtimes available | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | tail -1)"
	simulator="$(xcrun simctl create "$simulator_name" "$simulator_type" "$runtime")"
	# A new device posts its first-boot notices for about a minute, over whatever screen shows.
	xcrun simctl bootstatus "$simulator" -b >/dev/null
	sleep 60
fi

rm -rf "$output"
examination="$(EXAMINATION_SIMULATOR="$simulator" EXAMINATION_TOKEN="$token" EXAMINATION_DIRECTORY="$work" \
	scripts/start_screen_examination.sh light arriving)"
address="$(sed -n 's/^archive: //p' <<<"$examination")"
digest="$(sed -n 's/^scan digest: //p' <<<"$examination")"
xcrun simctl status_bar "$simulator" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
	--cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

# The archive answers 404 until the whole scan has arrived, at 40 KB a second.
appearance=light
for attempt in $(seq 120); do
	curl -sf -X POST "$address/scripted/documents" \
		-d "{\"content_sha256\": \"$digest\", \"status\": \"recognizing_text\"}" >/dev/null && break
	if [ "$attempt" -eq 120 ]; then
		echo "error: the archive did not receive the scan within two minutes" >&2
		exit 1
	fi
	sleep 1
done
await_text '"AXValue" : "Recognizing text"' 150
# The archive answers one request at a time, so pictures the list asked for during the slow upload
# can go unanswered. A row asks again once 30 seconds have passed and it shows again, so the list
# scrolls its rows away and back.
sleep 32
axe swipe --start-x 220 --start-y 750 --end-x 220 --end-y 250 --udid "$simulator" >/dev/null
sleep 1
axe swipe --start-x 220 --start-y 250 --end-x 220 --end-y 750 --udid "$simulator" >/dev/null
sleep 2

for appearance in light dark; do
	mkdir -p "$output/$appearance"
	xcrun simctl ui "$simulator" appearance "$appearance"
	sleep 2
	for scene in "${scenes[@]}"; do
		"${scene#* }" "${scene%% *}"
	done
done
echo "$output"
