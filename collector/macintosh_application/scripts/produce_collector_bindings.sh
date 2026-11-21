#!/bin/bash
# The pre-build phase of the CollectionBindings target. It builds the Rust static library for the
# Xcode configuration and generates the Swift bindings from that exact library, because generated
# Swift that differs from the linked library ends the application at launch with a checksum
# mismatch. A generated file is replaced only when it changed, so an unchanged build compiles
# nothing. Xcode passes SRCROOT, DERIVED_FILE_DIR, CARGO_PROFILE, CARGO_PROFILE_DIRECTORY, and
# MACOSX_DEPLOYMENT_TARGET, which cargo then applies to the C objects of SQLite and ring as well.
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

workspace="$SRCROOT/.."
target_directory="$workspace/target/aarch64-apple-darwin"
# Two invocations, so that the command-line features of the generator stay out of the library.
cargo build --quiet --locked --manifest-path "$workspace/Cargo.toml" --target aarch64-apple-darwin \
	--profile "$CARGO_PROFILE" -p collection_bindings
cargo build --quiet --locked --manifest-path "$workspace/Cargo.toml" --target aarch64-apple-darwin \
	-p collection_bindings_generator

staging="$DERIVED_FILE_DIR/collector_bindings"
rm -rf "$staging"
"$target_directory/debug/uniffi-bindgen-swift" --swift-sources --headers --modulemap --metadata-no-deps \
	--module-name collection_bindingsFFI --modulemap-filename module.modulemap \
	"$target_directory/$CARGO_PROFILE_DIRECTORY/libcollection_bindings.a" "$staging"

bindings="$SRCROOT/generated_bindings"
mkdir -p "$bindings/foreign_function_interface"
replace_when_changed() {
	cmp -s "$1" "$2" || cp "$1" "$2"
}
replace_when_changed "$staging/collection_bindings.swift" "$bindings/collection_bindings.swift"
replace_when_changed "$staging/collection_bindingsFFI.h" "$bindings/foreign_function_interface/collection_bindingsFFI.h"
replace_when_changed "$staging/module.modulemap" "$bindings/foreign_function_interface/module.modulemap"
