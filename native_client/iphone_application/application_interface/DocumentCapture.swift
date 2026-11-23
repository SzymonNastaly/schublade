import PhotosUI
import ScanRequest
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

	func scan(animated: Bool) {
		guard VNDocumentCameraViewController.isSupported else {
			alert("Scanning Is Not Available", "This device has no camera that can scan documents.")
			return
		}
		let camera = VNDocumentCameraViewController()
		camera.delegate = self
		presentOnTop(camera, animated: animated)
	}

	/// Over whatever shows already, such as the search, which the library presents.
	private func presentOnTop(_ controller: UIViewController, animated: Bool) {
		guard var top = presenter else {
			return
		}
		while let presented = top.presentedViewController, !presented.isBeingDismissed {
			top = presented
		}
		top.present(controller, animated: animated)
	}

	/// Answers a pending scan request from outside the application: the camera, unless it shows
	/// already, or for a restricted token an alert that says why this iPhone cannot send.
	func answerScanRequest(in navigation: UINavigationController, sendingPermitted: Bool, animated: Bool) {
		guard navigation.viewIfLoaded?.window != nil, ScanRequestCenter.shared.take(),
		      !(navigation.presentedViewController is VNDocumentCameraViewController)
		else {
			return
		}
		navigation.popToRootViewController(animated: false)
		let answer = { [weak self] in
			if sendingPermitted {
				self?.scan(animated: animated)
			} else {
				let alert = UIAlertController(
					title: "This iPhone Cannot Send",
					message: ConnectedArchive.restrictionSentence,
					preferredStyle: .alert
				)
				alert.addAction(UIAlertAction(title: "OK", style: .default))
				self?.presentOnTop(alert, animated: true)
			}
		}
		guard let presented = presenter?.presentedViewController ?? navigation.presentedViewController else {
			answer()
			return
		}
		presented.dismiss(animated: true, completion: answer)
	}

	func choosePhotos() {
		var configuration = PHPickerConfiguration()
		configuration.filter = .images
		configuration.selectionLimit = Self.selectionLimit
		let picker = PHPickerViewController(configuration: configuration)
		picker.delegate = self
		presentOnTop(picker, animated: true)
	}

	func chooseFiles() {
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .image], asCopy: true)
		picker.allowsMultipleSelection = true
		picker.delegate = self
		presentOnTop(picker, animated: true)
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
		let savedAt = Date.now
		let name = "Scan \(Self.scanNameFormatter.string(from: savedAt))"
		Task {
			// The row lands during the dismissal with the first page as its picture, before the PDF
			// is written.
			let firstPage = await Self.reducedFirstPage(of: pages)
			let identifier = submissions.prepare(
				origin: .scan,
				pageCount: pages.count,
				firstPage: firstPage,
				startedAt: savedAt
			)
			do {
				let file = try await Self.writeScan(pages)
				try submissions.submit(
					document: file,
					fileName: "\(name).pdf",
					kind: .pdf,
					origin: .scan,
					pageCount: pages.count,
					picture: firstPage,
					preparedAs: identifier
				)
			} catch ScanDocumentWriter.WriteFailure.tooLarge {
				submissions.abandon(identifier)
				alert(
					"This Scan Is Too Large",
					"The archive accepts up to 25 MB. Scan the letter in two parts."
				)
			} catch {
				submissions.abandon(identifier)
				alert("The Scan Could Not Be Saved", error.localizedDescription)
			}
		}
	}

	@concurrent
	private static func reducedFirstPage(of pages: [UIImage]) async -> CGImage? {
		guard let first = pages.first else {
			return nil
		}
		let scale = CGFloat(SubmissionPicture.pixelLimit) / max(first.size.width, first.size.height, 1)
		let fitted = CGSize(width: first.size.width * scale, height: first.size.height * scale)
		return await first.byPreparingThumbnail(ofSize: fitted)?.cgImage
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
	/// Every chosen photo lands as a row at once, newest first in the order chosen, and each is
	/// copied and sent in turn.
	func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
		picker.dismiss(animated: true)
		let providers = results.map(\.itemProvider)
		let identifiers = prepare(providers.map { _ in nil }, origin: .importedPhoto)
		Task {
			for (provider, identifier) in zip(providers, identifiers) {
				do {
					let type = DocumentImport.preferredType(among: provider.registeredContentTypes) ?? .image
					let copy = try await Self.copyPicture(from: provider, as: type)
					try await submit(
						copy,
						type: type,
						suggestedName: provider.suggestedName,
						origin: .importedPhoto,
						preparedAs: identifier
					)
				} catch {
					submissions.abandon(identifier)
					alert("A Photo Could Not Be Added", error.localizedDescription)
				}
			}
		}
	}

	func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		let chosen = Array(urls.prefix(Self.selectionLimit))
		let identifiers = prepare(chosen.map(\.lastPathComponent), origin: .importedFile)
		Task {
			for (url, identifier) in zip(chosen, identifiers) {
				do {
					guard let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
						throw DocumentImport.ImportFailure.unacceptedKind(url.lastPathComponent)
					}
					try await submit(url, type: type, suggestedName: nil, origin: .importedFile, preparedAs: identifier)
				} catch {
					submissions.abandon(identifier)
					alert("\(url.lastPathComponent) Could Not Be Added", error.localizedDescription)
				}
			}
		}
	}

	private func prepare(_ fileNames: [String?], origin: SubmissionOrigin) -> [UUID] {
		let chosenAt = Date.now
		return fileNames.enumerated().map { index, fileName in
			submissions.prepare(
				origin: origin,
				fileName: fileName,
				startedAt: chosenAt.addingTimeInterval(-Double(index) / 1000)
			)
		}
	}

	private func submit(
		_ file: URL,
		type: UTType,
		suggestedName: String?,
		origin: SubmissionOrigin,
		preparedAs identifier: UUID
	) async throws {
		let imported = try await Self.convert(file, type: type, suggestedName: suggestedName)
		try await submissions.submit(
			document: imported.file,
			fileName: imported.fileName,
			kind: imported.kind,
			origin: origin,
			picture: SubmissionPicture.make(from: imported.file, kind: imported.kind),
			preparedAs: identifier
		)
	}

	@concurrent
	private static func convert(
		_ file: URL,
		type: UTType,
		suggestedName: String?
	) async throws -> DocumentImport.ImportedDocument {
		try DocumentImport.prepare(file: file, type: type, suggestedName: suggestedName)
	}

	/// Copies the picture a provider offers as `type` into a file the application owns, because the
	/// provider's file exists only during its callback.
	private static func copyPicture(from provider: NSItemProvider, as type: UTType) async throws -> URL {
		let directory = try DocumentImport.workingDirectory()
		return try await withCheckedThrowingContinuation { continuation in
			_ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
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
		presentOnTop(alert, animated: true)
	}
}
