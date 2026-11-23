import ApplicationBindings
import LibraryPresentation
import UIKit

/// Copies of an original under the name a person reads, for the share sheet and Quick Look.
enum OriginalCopies {
	/// The original under its suggested name in a directory of its own, because the cache names its
	/// files by content and another application shows the name it receives. Says why when the
	/// original cannot be had.
	static func namedCopy(
		of document: DocumentIdentifier,
		fileName: String,
		gateway: ApplicationGateway,
		presenter: UIViewController?
	) async -> URL? {
		do throws(RepresentationRefusal) {
			let original = try await gateway.original(document)
			let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
			let copy = directory.appending(path: fileName)
			do {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
				try FileManager.default.copyItem(at: URL(filePath: original.path), to: copy)
			} catch {
				alert("The Original Could Not Be Copied", error.localizedDescription, on: presenter)
				return nil
			}
			return copy
		} catch {
			let placeholder = LibraryFailureWording.originalRefusalPlaceholder(error, device: IphoneDevice.wording)
			alert(placeholder.title, placeholder.detail, on: presenter)
			return nil
		}
	}

	/// The share sheet with a named copy, whose directory goes once the sheet closes.
	static func share(
		_ document: DocumentIdentifier,
		fileName: String,
		gateway: ApplicationGateway,
		presenter: UIViewController?,
		source: (any UIPopoverPresentationControllerSourceItem)?
	) {
		Task {
			guard let copy = await namedCopy(of: document, fileName: fileName, gateway: gateway, presenter: presenter)
			else {
				return
			}
			let sheet = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
			sheet.popoverPresentationController?.sourceItem = source
			sheet.completionWithItemsHandler = { _, _, _, _ in
				try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
			}
			presenter?.present(sheet, animated: true)
		}
	}

	private static func alert(_ title: String, _ message: String, on presenter: UIViewController?) {
		let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: "OK", style: .default))
		presenter?.present(alert, animated: true)
	}
}
