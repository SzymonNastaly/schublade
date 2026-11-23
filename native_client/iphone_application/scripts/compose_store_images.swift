// Composes the App Store images: each chosen screenshot from capture_store_screenshots.sh in a thin
// device frame on the icon's blue, under a headline and a sentence. Writes 1320 by 2868 pixels to
// build/store_images/<appearance>/NN_<scene>.png on the Mac and prints the directory.
//   scripts/execute_on_macintosh.sh swift native_client/iphone_application/scripts/compose_store_images.swift [light|dark]
import AppKit

struct StoreImage {
	let screenshot: String
	let headline: String
	let sentence: String
}

/// The order of the App Store listing. Scenes 05 and 06 stay out: the context menu reads as a blur,
/// and the share sheet shows the scripted archive's address.
let images = [
	StoreImage(
		screenshot: "01_library_arriving",
		headline: "Every letter\nin one drawer",
		sentence: "Scan a letter and it files itself\nin your own archive."
	),
	StoreImage(
		screenshot: "04_document_details",
		headline: "The facts,\nread for you",
		sentence: "Amount, due date, and IBAN.\nOne tap copies them."
	),
	StoreImage(
		screenshot: "02_search_scope",
		headline: "Found\nin seconds",
		sentence: "Search by sender, category,\nor any word on the page."
	),
	StoreImage(
		screenshot: "03_document_original",
		headline: "Every original,\neven offline",
		sentence: "Your archive travels\nwith your iPhone."
	),
	StoreImage(
		screenshot: "07_settings",
		headline: "Scan from\nanywhere",
		sentence: "Home Screen, Control Center,\nAction Button, or Siri."
	),
]

// App Store Connect requires the 6.9-inch size, 1320 by 2868 pixels in portrait.
let canvas = CGSize(width: 1320, height: 2868)
let screenWidth: CGFloat = 940
let bezel: CGFloat = 22
/// The corner of the iPhone 17 Pro Max's screen as a share of its width, 186 of 1320 pixels.
let screenCornerShare: CGFloat = 186 / 1320
let headlineTop: CGFloat = 180
let deviceBottomMargin: CGFloat = 72

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
	NSColor(
		srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
		green: CGFloat((hex >> 8) & 0xFF) / 255,
		blue: CGFloat(hex & 0xFF) / 255,
		alpha: alpha
	)
}

/// The icon's gradient, from application_icon.svg.
let backgroundColors = [color(0x2C68C4), color(0x1A4FA6), color(0x123F8C)]
let headlineColor = NSColor.white
let sentenceColor = color(0xCDE4FF)

func centered(_ text: String, font: NSFont, color: NSColor, lineHeight: CGFloat) -> NSAttributedString {
	let paragraph = NSMutableParagraphStyle()
	paragraph.alignment = .center
	paragraph.minimumLineHeight = lineHeight
	paragraph.maximumLineHeight = lineHeight
	return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
}

/// App Store Connect refuses an image with an alpha channel, so the context skips it.
func compose(_ image: StoreImage, screenshot: NSImage) -> NSBitmapImageRep {
	guard let context = CGContext(
		data: nil,
		width: Int(canvas.width),
		height: Int(canvas.height),
		bitsPerComponent: 8,
		bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB)!,
		bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
	) else {
		fatalError("A bitmap of \(canvas) could not be made")
	}
	context.translateBy(x: 0, y: canvas.height)
	context.scaleBy(x: 1, y: -1)
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

	let bounds = CGRect(origin: .zero, size: canvas)
	NSGradient(colors: backgroundColors)?.draw(in: bounds, angle: 90)

	let headline = centered(
		image.headline,
		font: .systemFont(ofSize: 112, weight: .bold),
		color: headlineColor,
		lineHeight: 124
	)
	let headlineHeight = headline.boundingRect(with: CGSize(width: canvas.width - 160, height: 1000), options: .usesLineFragmentOrigin).height
	headline.draw(with: CGRect(x: 80, y: headlineTop, width: canvas.width - 160, height: headlineHeight), options: .usesLineFragmentOrigin)
	let sentence = centered(
		image.sentence,
		font: .systemFont(ofSize: 54, weight: .medium),
		color: sentenceColor,
		lineHeight: 68
	)
	let sentenceTop = headlineTop + headlineHeight + 36
	sentence.draw(with: CGRect(x: 80, y: sentenceTop, width: canvas.width - 160, height: 200), options: .usesLineFragmentOrigin)

	let screenHeight = screenWidth * screenshot.size.height / screenshot.size.width
	let screen = CGRect(
		x: (canvas.width - screenWidth) / 2,
		y: canvas.height - deviceBottomMargin - bezel - screenHeight,
		width: screenWidth,
		height: screenHeight
	)
	let screenRadius = screenWidth * screenCornerShare
	let device = screen.insetBy(dx: -bezel, dy: -bezel)
	let devicePath = NSBezierPath(roundedRect: device, xRadius: screenRadius + bezel, yRadius: screenRadius + bezel)

	NSGraphicsContext.saveGraphicsState()
	let shadow = NSShadow()
	shadow.shadowColor = color(0x061A3D, alpha: 0.45)
	shadow.shadowBlurRadius = 70
	shadow.shadowOffset = CGSize(width: 0, height: 30)
	shadow.set()
	color(0x0E0F12).setFill()
	devicePath.fill()
	NSGraphicsContext.restoreGraphicsState()

	color(0x3A3D44).setStroke()
	devicePath.lineWidth = 3
	devicePath.stroke()

	NSGraphicsContext.saveGraphicsState()
	NSBezierPath(roundedRect: screen, xRadius: screenRadius, yRadius: screenRadius).addClip()
	screenshot.draw(in: screen, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
	NSGraphicsContext.restoreGraphicsState()
	NSGraphicsContext.restoreGraphicsState()
	guard let picture = context.makeImage() else {
		fatalError("The bitmap of \(image.screenshot) could not be read")
	}
	return NSBitmapImageRep(cgImage: picture)
}

let appearance = CommandLine.arguments.dropFirst().first ?? "light"
guard ["light", "dark"].contains(appearance) else {
	FileHandle.standardError.write(Data("error: the appearance is light or dark, not \(appearance)\n".utf8))
	exit(1)
}
let application = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let input = application.appendingPathComponent("build/store_screenshots/\(appearance)")
let output = application.appendingPathComponent("build/store_images/\(appearance)")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for (index, image) in images.enumerated() {
	let source = input.appendingPathComponent("\(image.screenshot).png")
	guard let screenshot = NSImage(contentsOf: source) else {
		FileHandle.standardError.write(Data("error: \(source.path) is missing; run capture_store_screenshots.sh first\n".utf8))
		exit(1)
	}
	let composed = compose(image, screenshot: screenshot)
	let scene = image.screenshot.drop { $0 != "_" }.dropFirst()
	let name = String(format: "%02d_", index + 1) + scene + ".png"
	guard let png = composed.representation(using: .png, properties: [:]) else {
		fatalError("\(name) could not be encoded")
	}
	try png.write(to: output.appendingPathComponent(name))
}
print(output.path)
