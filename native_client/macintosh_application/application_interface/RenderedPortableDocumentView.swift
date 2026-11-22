import AppKit
import PDFKit

/// Direct `PDFPage.draw(with:to:)` stack inside a scroll view used by `InterfaceRenderer` because
/// `PDFView` draws blank under offscreen `cacheDisplay(in:to:)`.
final class RenderedPortableDocumentView: NSView {
	private final class PageCanvasView: NSView {
		var document: PDFDocument? {
			didSet {
				updateFrame()
				needsDisplay = true
			}
		}

		override var isFlipped: Bool {
			true
		}

		func updateFrame() {
			guard let document, document.pageCount > 0 else {
				frame = NSRect(x: 0, y: 0, width: 480, height: 640)
				return
			}
			let contentWidth: CGFloat = 520
			var totalHeight: CGFloat = 20
			for pageIndex in 0 ..< min(document.pageCount, 3) {
				if let page = document.page(at: pageIndex) {
					let mediaBox = page.bounds(for: .mediaBox)
					let aspect = mediaBox.width > 0 ? mediaBox.height / mediaBox.width : 1.414
					totalHeight += (contentWidth - 40) * aspect + 16
				}
			}
			frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(totalHeight, 640))
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
			let pageWidth = max(bounds.width - 40, 200)
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
		canvasView.frame.size.width = max(scrollView.contentSize.width, 400)
		canvasView.updateFrame()
	}

	func display(document: PDFDocument?) {
		canvasView.document = document
	}
}
