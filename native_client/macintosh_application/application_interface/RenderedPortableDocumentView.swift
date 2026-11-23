import AppKit
import PDFKit

/// Direct `PDFPage.draw(with:to:)` stack inside a scroll view used by `InterfaceRenderer` because
/// `PDFView` draws blank under offscreen `cacheDisplay(in:to:)`.
final class RenderedPortableDocumentView: NSView {
	private final class PageCanvasView: NSView {
		var document: PDFDocument? {
			didSet {
				needsDisplay = true
			}
		}

		override var isFlipped: Bool {
			true
		}

		/// Fits the pages to a width, as `PDFView` does with `autoScales`, and grows to hold them.
		func fit(width: CGFloat, minimumHeight: CGFloat) {
			var totalHeight: CGFloat = 20
			if let document {
				for pageIndex in 0 ..< min(document.pageCount, 3) {
					if let page = document.page(at: pageIndex) {
						let mediaBox = page.bounds(for: .mediaBox)
						let aspect = mediaBox.width > 0 ? mediaBox.height / mediaBox.width : 1.414
						totalHeight += Self.pageWidth(in: width) * aspect + 16
					}
				}
			}
			frame = NSRect(x: 0, y: 0, width: width, height: max(totalHeight, minimumHeight))
		}

		static func pageWidth(in width: CGFloat) -> CGFloat {
			max(width - 40, 200)
		}

		override func draw(_ dirtyRect: NSRect) {
			guard let context = NSGraphicsContext.current?.cgContext else {
				return
			}
			InterfacePalette.readerBackdrop.setFill()
			context.fill(dirtyRect)

			guard let document else {
				return
			}
			let pageWidth = Self.pageWidth(in: bounds.width)
			var verticalOffset: CGFloat = 20

			for pageIndex in 0 ..< min(document.pageCount, 3) {
				guard let page = document.page(at: pageIndex) else {
					continue
				}
				let mediaBox = page.bounds(for: .mediaBox)
				let scale = mediaBox.width > 0 ? pageWidth / mediaBox.width : 1
				let pageHeight = mediaBox.height * scale
				let pageRect = NSRect(x: 20, y: verticalOffset, width: pageWidth, height: pageHeight)

				if pageRect.intersects(dirtyRect) {
					context.saveGState()
					NSColor.white.setFill()
					context.fill(pageRect)
					context.translateBy(x: pageRect.minX, y: pageRect.maxY)
					context.scaleBy(x: scale, y: -scale)
					context.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
					page.draw(with: .mediaBox, to: context)
					context.restoreGState()

					NSColor.separatorColor.setStroke()
					NSBezierPath(rect: pageRect).stroke()
				}
				verticalOffset += pageHeight + 16
			}
		}
	}

	private let scrollView = NSScrollView()
	private let canvasView = PageCanvasView()

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		scrollView.documentView = canvasView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = true
		scrollView.backgroundColor = InterfacePalette.readerBackdrop
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(scrollView)

		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("Interface Builder is not used")
	}

	override func layout() {
		super.layout()
		canvasView.fit(width: scrollView.contentSize.width, minimumHeight: scrollView.contentSize.height)
	}

	func display(document: PDFDocument?) {
		canvasView.document = document
		needsLayout = true
	}
}
