#!/bin/bash
# The pre-build phase of the ApplicationBindings target of both applications. It builds the Rust
# static library for the Xcode platform and configuration and generates the Swift bindings from
# that exact library, because generated Swift that differs from the linked library ends the
# application at launch with a checksum mismatch. A generated file is replaced only when it
# changed, so an unchanged build compiles nothing. Xcode passes SRCROOT, PLATFORM_NAME,
# DERIVED_FILE_DIR, CARGO_PROFILE, CARGO_PROFILE_DIRECTORY, and the deployment target of its
# platform, which cargo then applies to the C objects of SQLite and ring as well.
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

workspace="$(cd "$(dirname "$0")/.." && pwd)"
case "$PLATFORM_NAME" in
	macosx) target=aarch64-apple-darwin ;;
	iphoneos) target=aarch64-apple-ios ;;
	iphonesimulator) target=aarch64-apple-ios-sim ;;
	*)
		echo "error: no Rust target for the platform $PLATFORM_NAME" >&2
		exit 1
		;;
esac

cargo build --quiet --locked --manifest-path "$workspace/Cargo.toml" --target "$target" \
	--profile "$CARGO_PROFILE" -p application_bindings
# The generator runs on the Mac, so it is built without the SDK and deployment target that Xcode
# set for an iPhone build, and in its own invocation, so its command-line features stay out of
# the library.
env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET \
	cargo build --quiet --locked --manifest-path "$workspace/Cargo.toml" --target aarch64-apple-darwin \
	-p application_bindings_generator

staging="$DERIVED_FILE_DIR/application_bindings"
rm -rf "$staging"
"$workspace/target/aarch64-apple-darwin/debug/uniffi-bindgen-swift" --swift-sources --headers --modulemap \
	--metadata-no-deps --module-name application_bindingsFFI --modulemap-filename module.modulemap \
	"$workspace/target/$target/$CARGO_PROFILE_DIRECTORY/libapplication_bindings.a" "$staging"

bindings="$SRCROOT/generated_bindings"
mkdir -p "$bindings/foreign_function_interface"
replace_when_changed() {
	cmp -s "$1" "$2" || cp "$1" "$2"
}
replace_when_changed "$staging/application_bindings.swift" "$bindings/application_bindings.swift"
replace_when_changed "$staging/application_bindingsFFI.h" "$bindings/foreign_function_interface/application_bindingsFFI.h"
replace_when_changed "$staging/module.modulemap" "$bindings/foreign_function_interface/module.modulemap"
