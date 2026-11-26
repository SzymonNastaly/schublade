import CoreGraphics
import Vision

/// Vision's text recognition of one upright page, in German and English.
public enum PageTextRecognition {
	/// The longer side of a page drawn for recognition: an A4 page at about 300 dots per inch.
	static let pixelLimit = 3500

	/// The recognized lines in Vision's reading order, or an empty text when Vision read nothing.
	public static func text(of page: CGImage) -> String {
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.recognitionLanguages = ["de-DE", "en-US"]
		request.usesLanguageCorrection = true
		do {
			try VNImageRequestHandler(cgImage: page, orientation: .up).perform([request])
		} catch {
			return ""
		}
		return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
	}
}
