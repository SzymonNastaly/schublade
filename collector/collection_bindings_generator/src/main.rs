//! Writes the Swift source, the C header, and the module map of `collection_bindings` from the
//! static library it is given, which must be the library the application links.

fn main() {
    uniffi::uniffi_bindgen_swift();
}
