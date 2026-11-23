import UIKit

/// The icon, the name, and the version and build, centred in the last section of Settings, which has no rows.
final class SettingsAboutView: UICollectionReusableView {
	override init(frame: CGRect) {
		super.init(frame: frame)
		let icon = UIImageView(image: UIImage(named: "ApplicationIconPicture"))
		icon.layer.cornerRadius = 14
		icon.layer.cornerCurve = .continuous
		icon.clipsToBounds = true
		let name = UILabel()
		name.text = "Schublade"
		name.font = .preferredFont(forTextStyle: .headline)
		name.adjustsFontForContentSizeCategory = true
		let version = UILabel()
		let information = Bundle.main.infoDictionary ?? [:]
		let shortVersion = information["CFBundleShortVersionString"] as? String ?? "?"
		let build = information["CFBundleVersion"] as? String ?? "?"
		version.text = "Version \(shortVersion) (\(build))"
		version.font = .preferredFont(forTextStyle: .footnote)
		version.adjustsFontForContentSizeCategory = true
		version.textColor = .secondaryLabel
		let stack = UIStackView(arrangedSubviews: [icon, name, version])
		stack.axis = .vertical
		stack.alignment = .center
		stack.spacing = 4
		stack.setCustomSpacing(10, after: icon)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			icon.widthAnchor.constraint(equalToConstant: 60),
			icon.heightAnchor.constraint(equalToConstant: 60),
			stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
		])
		isAccessibilityElement = true
		accessibilityLabel = "Schublade, version \(shortVersion), build \(build)"
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}
}
