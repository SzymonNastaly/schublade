import AppKit
import PDFKit

/// The reader's panes, of which one shows at a time, each filling the reader.
extension DocumentReaderViewController {
	func configureContentPanes() {
		pdfView.autoScales = true
		pdfView.displayMode = .singlePageContinuous
		pdfView.displaysPageBreaks = true
		pdfView.backgroundColor = InterfacePalette.readerBackdrop
		pdfView.setAccessibilityIdentifier(InterfaceIdentifier.readerPortableDocumentView)

		textView.isEditable = false
		textView.isRichText = false
		textView.font = NSFont.preferredFont(forTextStyle: .body)
		textView.textContainerInset = NSSize(width: 24, height: 20)
		textView.autoresizingMask = [.width]
		textView.setAccessibilityIdentifier(InterfaceIdentifier.readerTextView)

		textScrollView.documentView = textView
		textScrollView.hasVerticalScroller = true

		for pane in [pdfView, imageReaderView] {
			let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(originalDoubleClicked))
			doubleClick.numberOfClicksRequired = 2
			doubleClick.delaysPrimaryMouseButtonEvents = false
			pane.addGestureRecognizer(doubleClick)
		}

		// The panes run from the window's top edge, so the page and the text pass under the toolbar,
		// whose height their scroll views keep clear at the top of the content.
		for pane in [pdfView, renderedPdfView, imageReaderView, textScrollView, placeholderView] {
			pane.translatesAutoresizingMaskIntoConstraints = false
			pane.isHidden = true
			view.addSubview(pane)
			NSLayoutConstraint.activate([
				pane.topAnchor.constraint(
					equalTo: pane === placeholderView ? view.safeAreaLayoutGuide.topAnchor : view.topAnchor
				),
				pane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
				pane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
				pane.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			])
		}
	}

	@objc private func originalDoubleClicked() {
		onOpenOriginal()
	}
}
