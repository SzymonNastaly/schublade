/// Whether a page's text layer holds its text: at least 40 letters or digits and fewer than one
/// replacement character per ten of them. The rule of `is_readable_text_layer` in `archive_access`
/// and of `isReadableTextLayer` in `src/ingestion/document_text.ts`; a page that fails it goes to
/// recognition.
enum ReadableTextLayer {
	static func admits(_ text: String) -> Bool {
		var alphanumeric = 0
		var replacements = 0
		for scalar in text.unicodeScalars {
			let category = scalar.properties.generalCategory
			let isControl = category == .control && !["\t", "\n", "\r"].contains(scalar)
			if scalar.properties.isAlphabetic || [.decimalNumber, .letterNumber, .otherNumber].contains(category) {
				alphanumeric += 1
			} else if category == .privateUse || scalar == "\u{FFFD}" || isControl {
				replacements += 1
			}
		}
		return alphanumeric >= 40 && replacements * 10 < alphanumeric
	}
}
