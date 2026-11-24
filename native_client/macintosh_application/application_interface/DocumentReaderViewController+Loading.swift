import AppKit
import ApplicationBindings
import LibraryPresentation

/// The reader's reads of a document's original and text, each of which a newer selection overtakes.
extension DocumentReaderViewController {
	func loadOriginal(for document: DocumentIdentifier, detail: DocumentDetailPresentation?) {
		newestOriginalRequest &+= 1
		let requestNumber = newestOriginalRequest
		originalUnreadable = false
		requestedOriginalKind = detail?.originalKind
		if detail?.originalKind == .unprintedEmail {
			originalRefusal = .NotAvailableYet
			updateDisplayedContent()
			return
		}
		Task {
			await performLoadOriginal(requestNumber: requestNumber, document: document)
		}
	}

	func performLoadOriginal(requestNumber: UInt64, document: DocumentIdentifier) async {
		do {
			let localFile = try await queries.original(document)
			guard requestNumber == newestOriginalRequest, document == activeDocument else {
				return
			}
			originalRefusal = nil
			loadedOriginal = (document, URL(fileURLWithPath: localFile.path))
			if let portableDocument = await PortableDocumentLoader.openPortableDocument(atPath: localFile.path) {
				guard requestNumber == newestOriginalRequest, document == activeDocument else {
					return
				}
				loadedPortableDocument = portableDocument
				loadedImage = nil
			} else if let cgImage = await PortableDocumentLoader.decodeImage(atPath: localFile.path) {
				guard requestNumber == newestOriginalRequest, document == activeDocument else {
					return
				}
				loadedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
				loadedPortableDocument = nil
			} else {
				guard requestNumber == newestOriginalRequest, document == activeDocument else {
					return
				}
				originalUnreadable = true
			}
		} catch {
			guard requestNumber == newestOriginalRequest, document == activeDocument else {
				return
			}
			originalRefusal = error
		}
		updateDisplayedContent()
		showTextForMatchIfNeeded()
	}

	func loadText(for document: DocumentIdentifier) {
		newestTextRequest &+= 1
		let requestNumber = newestTextRequest
		requestedTextDocument = document
		Task {
			await performLoadText(requestNumber: requestNumber, document: document)
		}
	}

	func performLoadText(requestNumber: UInt64, document: DocumentIdentifier) async {
		do {
			let markdown = try await queries.extractedText(document)
			guard requestNumber == newestTextRequest, document == activeDocument else {
				return
			}
			loadedText = markdown
			textRefusal = nil
		} catch {
			guard requestNumber == newestTextRequest, document == activeDocument else {
				return
			}
			textRefusal = error
		}
		loadedTextDocument = document
		updateDisplayedContent()
		showTextForMatchIfNeeded()
	}
}
