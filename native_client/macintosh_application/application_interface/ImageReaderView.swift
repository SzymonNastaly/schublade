import AppKit

/// Magnifying scroll view displaying a raster image document original.
final class ImageReaderView: NSScrollView {
	private let imageView = NSImageView()
	private var imageHeightConstraint: NSLayoutConstraint?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		hasVerticalScroller = true
		hasHorizontalScroller = true
		allowsMagnification = true
		minMagnification = 0.25
		maxMagnification = 4.0
		drawsBackground = true
		backgroundColor = .underPageBackgroundColor

		imageView.imageScaling = .scaleProportionallyUpOrDown
		imageView.translatesAutoresizingMaskIntoConstraints = false
		imageView.setAccessibilityIdentifier(InterfaceIdentifier.readerImageView)

		let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
		container.addSubview(imageView)
		documentView = container

		NSLayoutConstraint.activate([
			imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
			imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
			imageView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
			imageView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
			imageView.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 24),
			imageView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	func display(image: NSImage?) {
		imageView.image = image
		magnification = 1.0
		guard let image, let container = documentView else {
			return
		}
		if let existing = imageHeightConstraint {
			imageView.removeConstraint(existing)
		}
		let width = max(contentSize.width - 48, 320)
		let aspect = image.size.width > 0 ? image.size.height / image.size.width : 1
		let height = max(width * aspect, 200)
		let constraint = imageView.heightAnchor.constraint(equalToConstant: height)
		constraint.isActive = true
		imageHeightConstraint = constraint
		container.frame = NSRect(
			x: 0,
			y: 0,
			width: max(contentSize.width, width + 48),
			height: max(contentSize.height, height + 48)
		)
	}
}
