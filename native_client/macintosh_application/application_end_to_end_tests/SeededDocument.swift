import Foundation

struct SeededDocument: Encodable {
	let identifier: String
	let title: String
	let documentDate: String
	let senderName: String
	let categoryName: String
	let summary: String

	enum CodingKeys: String, CodingKey {
		case identifier
		case title
		case documentDate = "document_date"
		case senderName = "sender_name"
		case categoryName = "category_name"
		case summary
	}
}
