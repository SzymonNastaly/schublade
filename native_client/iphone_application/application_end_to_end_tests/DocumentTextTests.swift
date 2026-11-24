import XCTest
@testable import ApplicationInterface

/// How the text page reads the archive's Markdown.
final class DocumentTextTests: XCTestCase {
	/// A letter's link to the web or to a mail address stays a link, and one into another
	/// application's scheme is plain text, because anyone could have sent the letter.
	@MainActor
	func testOnlyWebMailAndTelephoneLinksStayLinks() {
		let text = DocumentTextViewController.readableText(
			"[Portal](https://bank.example) [Mail](mailto:post@bank.example) [Run](shortcuts://run-shortcut?name=x)"
		)
		var links: [URL] = []
		text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
			if let link = value as? URL {
				links.append(link)
			}
		}
		XCTAssertEqual(links.map(\.absoluteString), ["https://bank.example", "mailto:post@bank.example"])
	}
}
