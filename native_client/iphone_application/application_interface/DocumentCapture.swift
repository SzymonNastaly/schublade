import PhotosUI
import SubmissionQueue
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Turns what a person scans or chooses into submissions: the system's document camera, Photos,
/// and Files. A scan needs no confirmation after Save, because the archive names and files it.
final class DocumentCapture: NSObject {
	/// "Scan 2026-11-22 21.30": sortable, and free of the colon that Files shows as a slash.
	private static let scanNameFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd HH.mm"
		return formatter
	}()

	/// The archive takes at most 20 files per upload, and the pickers offer as many at once.
	private static let selectionLimit = 20

	private weak var presenter: UIViewController?
	private let submissions: SubmissionCoordinator

	init(presenter: UIViewController, submissions: SubmissionCoordinator) {
		self.presenter = presenter
		self.submissions = submissions
	}

	func scan() {
		guard VNDocumentCameraViewController.isSupported else {
			alert("Scanning Is Not Available", "This device has no camera that can scan documents.")
			return
		}
		let camera = VNDocumentCameraViewController()
		camera.delegate = self
		presenter?.present(camera, animated: true)
	}

	func choosePhotos() {
		var configuration = PHPickerConfiguration()
		configuration.filter = .images
		configuration.selectionLimit = Self.selectionLimit
		let picker = PHPickerViewController(configuration: configuration)
		picker.delegate = self
		presenter?.present(picker, animated: true)
	}

	func chooseFiles() {
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .image], asCopy: true)
		picker.allowsMultipleSelection = true
		picker.delegate = self
		presenter?.present(picker, animated: true)
	}
}

/// The document camera.
extension DocumentCapture: VNDocumentCameraViewControllerDelegate {
	func documentCameraViewController(
		_ camera: VNDocumentCameraViewController,
		didFinishWith scan: VNDocumentCameraScan
	) {
		let pages = (0 ..< scan.pageCount).map { scan.imageOfPage(at: $0) }
		camera.dismiss(animated: true)
		let name = "Scan \(Self.scanNameFormatter.string(from: .now))"
		Task {
			do {
				let file = try await Self.writeScan(pages)
				try submissions.submit(
					document: file,
					fileName: "\(name).pdf",
					kind: .pdf,
					origin: .scan,
					pageCount: pages.count
				)
			} catch ScanDocumentWriter.WriteFailure.tooLarge {
				alert(
					"This Scan Is Too Large",
					"The archive accepts up to 25 MB. Scan the letter in two parts."
				)
			} catch {
				alert("The Scan Could Not Be Saved", error.localizedDescription)
			}
		}
	}

	func documentCameraViewControllerDidCancel(_ camera: VNDocumentCameraViewController) {
		camera.dismiss(animated: true)
	}

	func documentCameraViewController(_ camera: VNDocumentCameraViewController, didFailWithError error: any Error) {
		camera.dismiss(animated: true)
		alert("The Camera Stopped", error.localizedDescription)
	}

	@concurrent
	private static func writeScan(_ pages: [UIImage]) async throws -> URL {
		let file = try DocumentImport.workingDirectory().appending(path: "scan.pdf")
		_ = try ScanDocumentWriter.write(pages: pages, to: file)
		return file
	}
}

/// Photos and Files.
extension DocumentCapture: PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
	func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
		picker.dismiss(animated: true)
		let providers = results.map(\.itemProvider)
		Task {
			for provider in providers {
				do {
					let copy = try await Self.copyPicture(from: provider)
					try await submit(copy, suggestedName: provider.suggestedName, origin: .importedPhoto)
				} catch {
					alert("A Photo Could Not Be Added", error.localizedDescription)
				}
			}
		}
	}

	func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		Task {
			for url in urls.prefix(Self.selectionLimit) {
				do {
					try await submit(url, suggestedName: nil, origin: .importedFile)
				} catch {
					alert("\(url.lastPathComponent) Could Not Be Added", error.localizedDescription)
				}
			}
		}
	}

	private func submit(_ file: URL, suggestedName: String?, origin: SubmissionOrigin) async throws {
		let imported = try await Self.convert(file, suggestedName: suggestedName)
		try submissions.submit(
			document: imported.file,
			fileName: imported.fileName,
			kind: imported.kind,
			origin: origin
		)
	}

	@concurrent
	private static func convert(_ file: URL, suggestedName: String?) async throws -> DocumentImport.ImportedDocument {
		try DocumentImport.prepare(file: file, suggestedName: suggestedName)
	}

	/// Copies the picture a provider offers into a file the application owns, because the
	/// provider's file exists only during its callback.
	private static func copyPicture(from provider: NSItemProvider) async throws -> URL {
		let directory = try DocumentImport.workingDirectory()
		return try await withCheckedThrowingContinuation { continuation in
			_ = provider.loadFileRepresentation(for: .image, openInPlace: false) { url, _, error in
				guard let url else {
					continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
					return
				}
				let copy = directory.appending(path: url.lastPathComponent)
				do {
					try FileManager.default.copyItem(at: url, to: copy)
					continuation.resume(returning: copy)
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}

	private func alert(_ title: String, _ message: String) {
		let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: "OK", style: .default))
		presenter?.present(alert, animated: true)
	}
}
