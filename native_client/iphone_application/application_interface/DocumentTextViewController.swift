import ApplicationBindings
import LibraryPresentation
import UIKit

final class DocumentTextViewController: UIViewController {
	enum TextState: Equatable {
		case loading
		case text(String)
		case unavailable(RepresentationPlaceholder)
	}

	private let gateway: ApplicationGateway
	private let document: DocumentIdentifier
	private(set) var state = TextState.loading
	private var newestRequest: UInt64 = 0
	let textView = UITextView()

	init(gateway: ApplicationGateway, document: DocumentIdentifier) {
		self.gateway = gateway
		self.document = document
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .systemBackground
		textView.isEditable = false
		textView.adjustsFontForContentSizeCategory = true
		textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
		textView.backgroundColor = .systemBackground
		textView.dataDetectorTypes = [.link, .phoneNumber]
		textView.accessibilityIdentifier = "document.text"
		textView.frame = view.bounds
		textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		view.addSubview(textView)
		load()
	}

	func contentRevisionChanged() {
		if case .unavailable = state {
			load()
		}
	}

	private func load() {
		newestRequest &+= 1
		let request = newestRequest
		Task {
			let next: TextState
			do throws(RepresentationRefusal) {
				next = try await .text(gateway.extractedText(document))
			} catch {
				next = .unavailable(LibraryFailureWording.extractedTextRefusalPlaceholder(error))
			}
			guard request == newestRequest else {
				return
			}
			show(next)
		}
	}

	private func show(_ next: TextState) {
		state = next
		textView.isHidden = true
		switch next {
		case .loading:
			contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
		case let .text(markdown):
			contentUnavailableConfiguration = nil
			textView.attributedText = Self.readableText(markdown)
			textView.isHidden = false
		case let .unavailable(placeholder):
			var configuration = UIContentUnavailableConfiguration.empty()
			configuration.image = UIImage(systemName: "text.page.slash")
			configuration.text = placeholder.title
			configuration.secondaryText = placeholder.detail
			if placeholder.canRetry {
				configuration.button = .plain()
				configuration.button.title = "Try Again"
				configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
			}
			contentUnavailableConfiguration = configuration
		}
	}

	private static func readableText(_ markdown: String) -> NSAttributedString {
		let body: [NSAttributedString.Key: Any] = [
			.font: UIFont.preferredFont(forTextStyle: .body),
			.foregroundColor: UIColor.label,
		]
		let heading: [NSAttributedString.Key: Any] = [
			.font: UIFont.preferredFont(forTextStyle: .title3, compatibleWith: nil).withWeight(.semibold),
			.foregroundColor: UIColor.label,
		]
		let text = NSMutableAttributedString()
		for (index, line) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
			if index > 0 {
				text.append(NSAttributedString(string: "\n", attributes: body))
			}
			let words = line.drop { $0 == "#" }
			if words.count < line.count, words.first == " " {
				text.append(NSAttributedString(string: String(words.dropFirst()), attributes: heading))
			} else {
				text.append(NSAttributedString(string: String(line), attributes: body))
			}
		}
		return text
	}
}

private extension UIFont {
	func withWeight(_ weight: UIFont.Weight) -> UIFont {
		let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
		return UIFont(descriptor: descriptor, size: 0)
	}
}
