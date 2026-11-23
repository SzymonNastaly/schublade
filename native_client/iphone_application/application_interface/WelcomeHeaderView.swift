import UIKit

/// The icon, the title, and the sentence that says what Schublade does, centred above the form.
final class WelcomeHeaderView: UICollectionReusableView {
	override init(frame: CGRect) {
		super.init(frame: frame)
		let icon = UIImageView(image: UIImage(named: "ApplicationIconPicture"))
		icon.layer.cornerRadius = 20
		icon.layer.cornerCurve = .continuous
		icon.clipsToBounds = true
		icon.isAccessibilityElement = false
		let title = UILabel()
		title.text = "Connect Your Archive"
		// At the largest text sizes a word of the title would break across lines, so it grows only
		// until "Archive" still fits the width of a phone.
		title.font = UIFontMetrics(forTextStyle: .title1).scaledFont(
			for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .title1, compatibleWith: .init(
				preferredContentSizeCategory: .large
			)).pointSize, weight: .bold),
			maximumPointSize: 44
		)
		title.adjustsFontForContentSizeCategory = true
		title.textAlignment = .center
		title.numberOfLines = 0
		title.accessibilityTraits = .header
		let sentence = UILabel()
		sentence.text = "Schublade sends your letters to your own archive and keeps every document at hand, even offline."
		sentence.font = .preferredFont(forTextStyle: .body)
		sentence.adjustsFontForContentSizeCategory = true
		sentence.textColor = .secondaryLabel
		sentence.textAlignment = .center
		sentence.numberOfLines = 0
		let stack = UIStackView(arrangedSubviews: [icon, title, sentence])
		stack.axis = .vertical
		stack.alignment = .center
		stack.spacing = 12
		stack.setCustomSpacing(20, after: icon)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			icon.widthAnchor.constraint(equalToConstant: 88),
			icon.heightAnchor.constraint(equalToConstant: 88),
			stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
			stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 8),
			stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -8),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}
}
