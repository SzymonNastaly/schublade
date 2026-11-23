import UIKit

/// A label and its field in one row, side by side, or the label above the field at an
/// accessibility text size.
final class FormFieldView: UIView {
	private let stack: UIStackView
	/// Holds the field to the row's width while it sits under its label.
	private let stackedWidth: NSLayoutConstraint

	init(label text: String, field: UITextField, accessory: UIView?) {
		let label = UILabel()
		label.text = text
		label.font = .preferredFont(forTextStyle: .body)
		label.adjustsFontForContentSizeCategory = true
		label.isAccessibilityElement = false
		label.setContentCompressionResistancePriority(.required, for: .horizontal)
		// Both labels take one width, so the two fields begin under each other.
		let width = label.widthAnchor.constraint(
			equalToConstant: UIFontMetrics(forTextStyle: .body).scaledValue(for: 76)
		)
		width.priority = .defaultHigh
		width.isActive = true
		field.setContentHuggingPriority(.defaultLow, for: .horizontal)
		let line = UIStackView(arrangedSubviews: [field] + (accessory.map { [$0] } ?? []))
		line.spacing = 8
		line.alignment = .center
		accessory?.setContentHuggingPriority(.required, for: .horizontal)
		accessory?.setContentCompressionResistancePriority(.required, for: .horizontal)
		stack = UIStackView(arrangedSubviews: [label, line])
		stack.spacing = 12
		stackedWidth = line.widthAnchor.constraint(equalTo: stack.widthAnchor)
		super.init(frame: .zero)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			// As tall as the Paste button, so a row keeps its height when Paste shows.
			heightAnchor.constraint(
				greaterThanOrEqualToConstant: UIFontMetrics(forTextStyle: .body).scaledValue(for: 34)
			),
		])
		arrange()
		registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: FormFieldView, _) in
			view.arrange()
		}
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	private func arrange() {
		let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
		stack.axis = stacked ? .vertical : .horizontal
		stack.alignment = stacked ? .leading : .center
		stack.spacing = stacked ? 4 : 12
		stackedWidth.isActive = stacked
	}
}

/// A token pasted with the Paste button takes the field's whole text, without the spaces and line
/// breaks a copy from the browser can bring.
final class TokenField: UITextField {
	override func paste(itemProviders: [NSItemProvider]) {
		guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else {
			return
		}
		_ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
			guard let text else {
				return
			}
			let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
			Task { @MainActor in
				self?.text = token
				self?.sendActions(for: .editingChanged)
			}
		}
	}
}

extension UICollectionViewListCell {
	/// Puts a view of the form in the cell, inside its margins, or filling it to its edges.
	func host(_ content: UIView, fillingCell: Bool = false) {
		contentConfiguration = nil
		contentView.subviews.forEach { $0.removeFromSuperview() }
		content.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(content)
		let margins = contentView.layoutMarginsGuide
		NSLayoutConstraint.activate([
			content.topAnchor.constraint(equalTo: fillingCell ? contentView.topAnchor : margins.topAnchor),
			content.bottomAnchor.constraint(equalTo: fillingCell ? contentView.bottomAnchor : margins.bottomAnchor),
			content.leadingAnchor.constraint(equalTo: fillingCell ? contentView.leadingAnchor : margins.leadingAnchor),
			content.trailingAnchor.constraint(
				equalTo: fillingCell ? contentView.trailingAnchor : margins.trailingAnchor
			),
		])
	}
}
