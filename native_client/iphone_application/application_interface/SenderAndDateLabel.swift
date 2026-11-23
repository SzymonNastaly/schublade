import LibraryPresentation
import UIKit

/// The text of a row's second line, and at an accessibility size of the amount's line.
enum RowCaptionText {
	/// The subheadline's 15 points at the default text size, with digits of one width, so the amounts
	/// of the rows form a column.
	static var amountFont: UIFont {
		UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedDigitSystemFont(
			ofSize: 15,
			weight: .medium
		))
	}

	/// The date in the sender's colour, then the amount, for the amount's own line.
	static func dateAndAmount(_ row: DocumentRowPresentation) -> NSAttributedString? {
		guard row.dateText != nil || row.amountText != nil else {
			return nil
		}
		let line = NSMutableAttributedString()
		if let date = row.dateText {
			line.append(NSAttributedString(string: date, attributes: [
				.font: UIFont.preferredFont(forTextStyle: .subheadline),
				.foregroundColor: UIColor.secondaryLabel,
			]))
		}
		if let amount = row.amountText {
			if line.length > 0 {
				line.append(NSAttributedString(string: " · ", attributes: [
					.font: UIFont.preferredFont(forTextStyle: .subheadline),
					.foregroundColor: UIColor.secondaryLabel,
				]))
			}
			line.append(NSAttributedString(
				string: amount,
				attributes: [.font: amountFont, .foregroundColor: UIColor.label]
			))
		}
		return line
	}
}

/// The sender and the date on one line. A long sender is cut short with its ellipsis right before
/// the date's separator, "Werkhof Ba… · 17 Oct", which a label of its own beside the date would
/// leave apart by what remains of its width.
final class SenderAndDateLabel: UILabel {
	private static let separator = " · "
	private var sender = ""
	private var date: String?

	func show(sender: String, date: String?) {
		self.sender = sender
		self.date = date
		fit()
		setNeedsLayout()
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		fit()
	}

	private func fit() {
		let fitted = Self.fitted(sender: sender, date: date, font: font, width: bounds.width)
		if text != fitted {
			text = fitted
		}
	}

	/// The whole line when it fits in `width`, else the longest start of the sender that fits with an
	/// ellipsis and the date, else the date alone.
	static func fitted(sender: String, date: String?, font: UIFont, width: CGFloat) -> String {
		guard let date else {
			return sender
		}
		guard !sender.isEmpty else {
			return date
		}
		let whole = sender + separator + date
		func fits(_ text: String) -> Bool {
			NSAttributedString(string: text, attributes: [.font: font]).size().width.rounded(.up) <= width
		}
		guard width > 0, !fits(whole) else {
			return whole
		}
		let characters = Array(sender)
		var shortest = 1
		var longest = characters.count - 1
		var best: String?
		while shortest <= longest {
			let count = (shortest + longest) / 2
			let start = String(characters[..<count]).trimmingCharacters(in: .whitespaces)
			let candidate = start + "…" + separator + date
			if fits(candidate) {
				best = candidate
				shortest = count + 1
			} else {
				longest = count - 1
			}
		}
		return best ?? date
	}
}
