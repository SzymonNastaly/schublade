import LibraryPresentation
import UIKit

struct DocumentRowContent: UIContentConfiguration, Equatable {
	/// A page of A4 in the row's height.
	static let pictureSize = CGSize(width: 40, height: 52)
	/// Where the text begins, for the separator below the row.
	static let textLeading: CGFloat = 16 + pictureSize.width + 14

	let row: DocumentRowPresentation
	let picture: UIImage?

	func makeContentView() -> any UIView & UIContentView {
		DocumentRowContentView(configuration: self)
	}

	func updated(for _: any UIConfigurationState) -> DocumentRowContent {
		self
	}
}

final class DocumentRowContentView: UIView, UIContentView {
	private let pictureView = UIImageView()
	private let titleLabel = UILabel()
	private let amountLabel = UILabel()
	private let senderLabel = UILabel()
	private let dateLabel = UILabel()
	private let passageLabel = UILabel()
	private var shown: DocumentRowContent

	var configuration: any UIContentConfiguration {
		get { shown }
		set {
			guard let next = newValue as? DocumentRowContent, next != shown else {
				return
			}
			shown = next
			apply(next)
		}
	}

	init(configuration: DocumentRowContent) {
		shown = configuration
		super.init(frame: .zero)
		build()
		apply(configuration)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	private func build() {
		pictureView.contentMode = .scaleAspectFit
		pictureView.layer.cornerRadius = 4
		pictureView.clipsToBounds = true
		pictureView.tintColor = InterfacePalette.archive
		style(titleLabel, .headline, color: .label, lines: 2)
		style(amountLabel, .subheadline, color: .label, lines: 1)
		amountLabel.font = Self.amountFont
		amountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		amountLabel.setContentHuggingPriority(.required, for: .horizontal)
		style(senderLabel, .subheadline, color: .secondaryLabel, lines: 1)
		style(dateLabel, .subheadline, color: .secondaryLabel, lines: 1)
		// A long sender gives way, and the date stays whole.
		dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		dateLabel.setContentHuggingPriority(.required, for: .horizontal)
		senderLabel.setContentHuggingPriority(.required, for: .horizontal)
		let caption = UIStackView(arrangedSubviews: [senderLabel, dateLabel, UIView()])
		caption.alignment = .firstBaseline
		style(passageLabel, .footnote, color: .secondaryLabel, lines: 2)
		let titleLine = UIStackView(arrangedSubviews: [titleLabel, amountLabel])
		titleLine.alignment = .firstBaseline
		titleLine.spacing = 12
		let text = UIStackView(arrangedSubviews: [titleLine, caption, passageLabel])
		text.axis = .vertical
		text.spacing = 3
		text.setCustomSpacing(4, after: titleLine)
		for subview in [pictureView, text] as [UIView] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			addSubview(subview)
		}
		// The row is as tall as the taller of the picture and the text, which both stay above its bottom.
		let shortest = heightAnchor.constraint(equalToConstant: 0)
		shortest.priority = .defaultLow
		directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
		NSLayoutConstraint.activate([
			pictureView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
			pictureView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
			pictureView.widthAnchor.constraint(equalToConstant: DocumentRowContent.pictureSize.width),
			pictureView.heightAnchor.constraint(equalToConstant: DocumentRowContent.pictureSize.height),
			pictureView.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor),
			text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DocumentRowContent.textLeading),
			text.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
			text.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
			text.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor),
			shortest,
		])
	}

	private func style(_ label: UILabel, _ style: UIFont.TextStyle, color: UIColor, lines: Int) {
		label.font = .preferredFont(forTextStyle: style)
		label.adjustsFontForContentSizeCategory = true
		label.textColor = color
		label.numberOfLines = lines
	}

	private func apply(_ content: DocumentRowContent) {
		let row = content.row
		pictureView.image = content.picture ?? UIImage(systemName: "doc.text")
		pictureView.contentMode = content.picture == nil ? .center : .scaleAspectFit
		pictureView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
		titleLabel.text = row.title
		amountLabel.text = row.amountText
		amountLabel.isHidden = row.amountText == nil
		senderLabel.text = row.sender
		senderLabel.isHidden = row.sender.isEmpty
		dateLabel.text = row.dateText.map { row.sender.isEmpty ? $0 : " · \($0)" }
		dateLabel.isHidden = row.dateText == nil
		passageLabel.text = row.thirdLineText
		passageLabel.isHidden = row.thirdLineText.isEmpty
		passageLabel.textColor = switch row.thirdLineTone {
		case .secondary: .secondaryLabel
		case .accent: InterfacePalette.archive
		case .failure: InterfacePalette.attention
		}
	}

	/// The subheadline, 15 points at the default text size, with digits of one width, so the amounts
	/// of the rows align.
	private static var amountFont: UIFont {
		UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedDigitSystemFont(
			ofSize: 15,
			weight: .medium
		))
	}
}
