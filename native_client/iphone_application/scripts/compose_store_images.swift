// Composes the App Store images: each chosen screenshot from capture_store_screenshots.sh in a thin
// device frame on the icon's blue, under a headline and a sentence, with one accent that shows the
// benefit at a glance. Writes 1320 by 2868 pixels to build/store_images/<appearance>/NN_<scene>.png
// on the Mac and prints the directory.
//   scripts/execute_on_macintosh.sh swift native_client/iphone_application/scripts/compose_store_images.swift
//   [light|dark]
import AppKit
import PDFKit

/// What an image adds to its screenshot. A callout is real interface, so the App Store's rule that
/// screenshots show the application in use still holds.
enum Accent {
	/// A paper letter and the mark of a PDF tucked behind the phone's top corners: what goes in.
	case paperAndPDF(letter: String)
	/// A part of the screenshot, given in its pixels, lifted out of the phone and enlarged.
	case callout(crop: CGRect, cornerRadius: CGFloat, scale: CGFloat)
	/// Labelled symbols on the phone's top edge.
	case symbols([(symbol: String, tint: UInt32)])
	/// A pill on the phone's top edge.
	case pill(symbol: String, tint: UInt32, text: String)
}

struct StoreImage {
	let screenshot: String
	let headline: String
	let sentence: String
	let accent: Accent
}

/// The order of the App Store listing. Scenes 05 and 06 stay out: the context menu reads as a blur,
/// and the share sheet shows the scripted archive's address.
let images = [
	StoreImage(
		screenshot: "01_library_arriving",
		headline: "Every letter\nin one drawer",
		sentence: "Scan paper or share a PDF.\nIt lands in your own archive.",
		accent: .paperAndPDF(letter: "test_fixtures/documents/electricity_invoice_scanned.pdf")
	),
	StoreImage(
		screenshot: "04_document_details",
		headline: "The facts,\nread for you",
		sentence: "Amount, due date, and IBAN.\nOne tap copies them.",
		accent: .callout(crop: CGRect(x: 84, y: 1790, width: 1152, height: 748), cornerRadius: 58, scale: 1.16)
	),
	StoreImage(
		screenshot: "02_search_scope",
		headline: "Found\nin seconds",
		sentence: "Search by sender, category,\nor any word on the page.",
		accent: .callout(crop: CGRect(x: 84, y: 2643, width: 1152, height: 142), cornerRadius: 71, scale: 1.2)
	),
	StoreImage(
		screenshot: "03_document_original",
		headline: "Every original,\neven offline",
		sentence: "Your archive travels\nwith your iPhone.",
		accent: .pill(symbol: "airplane", tint: 0xFF9500, text: "Airplane Mode")
	),
	StoreImage(
		screenshot: "07_settings",
		headline: "Scan from\nanywhere",
		sentence: "Home Screen, Control Center,\nAction Button, or Siri.",
		accent: .symbols([
			(symbol: "apps.iphone", tint: 0x0B5CBF),
			(symbol: "switch.2", tint: 0x0B5CBF),
			(symbol: "button.horizontal.top.press", tint: 0x0B5CBF),
			(symbol: "mic.fill", tint: 0x0B5CBF),
		])
	),
]

// App Store Connect requires the 6.9-inch size, 1320 by 2868 pixels in portrait.
let canvas = CGSize(width: 1320, height: 2868)
let screenWidth: CGFloat = 930
/// The corner of the iPhone 17 Pro Max's screen as a share of its width, 186 of 1320 pixels.
let screenCornerShare: CGFloat = 186 / 1320
/// Apple's product bezel of the iPhone 17 Pro Max in Silver, from Bezel-iPhone-17.dmg of the Apple
/// Design Resources, whose license allows it in mock-ups but not in this repository: 1470 by 3000
/// pixels with the Dynamic Island drawn and the 1320 by 2868 screen clear.
let bezelPath = NSString(string: "~/apple_design_resources/iPhone 17 Pro Max - Silver - Portrait.png")
	.expandingTildeInPath
let bezelSize = CGSize(width: 1470, height: 3000)
let bezelScreenOrigin = CGPoint(x: 75, y: 66)
let headlineTop: CGFloat = 170
let deviceBottomMargin: CGFloat = 60

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
	return NSAttributedString(
		string: text,
		attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
	)
}

/// Draws what `body` draws with a soft shadow below it.
func withShadow(blur: CGFloat = 60, offset: CGFloat = 26, alpha: CGFloat = 0.4, _ body: () -> Void) {
	NSGraphicsContext.saveGraphicsState()
	let shadow = NSShadow()
	shadow.shadowColor = color(0x061A3D, alpha: alpha)
	shadow.shadowBlurRadius = blur
	shadow.shadowOffset = CGSize(width: 0, height: offset)
	shadow.set()
	body()
	NSGraphicsContext.restoreGraphicsState()
}

/// Draws `body` turned by `degrees` around the centre of `frame`.
func rotated(_ degrees: CGFloat, around frame: CGRect, _ body: () -> Void) {
	NSGraphicsContext.saveGraphicsState()
	let turn = NSAffineTransform()
	turn.translateX(by: frame.midX, yBy: frame.midY)
	turn.rotate(byDegrees: degrees)
	turn.translateX(by: -frame.midX, yBy: -frame.midY)
	turn.concat()
	body()
	NSGraphicsContext.restoreGraphicsState()
}

func symbol(_ name: String, pointSize: CGFloat, tint: NSColor) -> NSImage {
	let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
		.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
	guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
		.withSymbolConfiguration(configuration)
	else {
		fatalError("The symbol \(name) is missing")
	}
	return image
}

/// Draws `image` at its own aspect ratio, centred in `frame`.
func drawCentered(_ image: NSImage, in frame: CGRect) {
	let fit = min(frame.width / image.size.width, frame.height / image.size.height)
	let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
	image.draw(
		in: CGRect(
			x: frame.midX - size.width / 2,
			y: frame.midY - size.height / 2,
			width: size.width,
			height: size.height
		),
		from: .zero,
		operation: .sourceOver,
		fraction: 1,
		respectFlipped: true,
		hints: nil
	)
}

/// The first page of a letter from the test documents, as paper with a slight turn.
func drawLetter(_ path: String, in frame: CGRect, degrees: CGFloat) {
	// A page draws only while its document lives.
	guard let document = PDFDocument(url: repository.appendingPathComponent(path)),
	      let page = document.page(at: 0)
	else {
		fatalError("\(path) has no first page")
	}
	let picture = withExtendedLifetime(document) {
		page.thumbnail(of: CGSize(width: frame.width * 2, height: frame.height * 2), for: .mediaBox)
	}
	rotated(degrees, around: frame) {
		withShadow(blur: 50, offset: 24, alpha: 0.45) {
			NSColor.white.setFill()
			NSBezierPath(rect: frame).fill()
		}
		picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
	}
}

/// The mark of a PDF file: a page with a folded corner and a red label.
func drawPDFMark(in frame: CGRect, degrees: CGFloat) {
	let fold = frame.width * 0.3
	let sheet = NSBezierPath()
	sheet.move(to: CGPoint(x: frame.minX, y: frame.minY + 24))
	sheet.appendArc(
		from: CGPoint(x: frame.minX, y: frame.minY),
		to: CGPoint(x: frame.minX + 24, y: frame.minY),
		radius: 24
	)
	sheet.line(to: CGPoint(x: frame.maxX - fold, y: frame.minY))
	sheet.line(to: CGPoint(x: frame.maxX, y: frame.minY + fold))
	sheet.appendArc(
		from: CGPoint(x: frame.maxX, y: frame.maxY),
		to: CGPoint(x: frame.maxX - 24, y: frame.maxY),
		radius: 24
	)
	sheet.appendArc(
		from: CGPoint(x: frame.minX, y: frame.maxY),
		to: CGPoint(x: frame.minX, y: frame.maxY - 24),
		radius: 24
	)
	sheet.close()
	let corner = NSBezierPath()
	corner.move(to: CGPoint(x: frame.maxX - fold, y: frame.minY))
	corner.line(to: CGPoint(x: frame.maxX - fold, y: frame.minY + fold - 14))
	corner.appendArc(
		from: CGPoint(x: frame.maxX - fold, y: frame.minY + fold),
		to: CGPoint(x: frame.maxX - fold + 14, y: frame.minY + fold),
		radius: 14
	)
	corner.line(to: CGPoint(x: frame.maxX, y: frame.minY + fold))
	corner.close()
	rotated(degrees, around: frame) {
		withShadow(blur: 50, offset: 24, alpha: 0.45) {
			NSColor.white.setFill()
			sheet.fill()
		}
		color(0xD8DEE8).setFill()
		corner.fill()
		color(0xC9D1DE).setFill()
		for line in 0 ..< 4 {
			let width = line == 3 ? frame.width * 0.38 : frame.width * 0.6
			NSBezierPath(
				roundedRect: CGRect(
					x: frame.minX + frame.width * 0.2,
					y: frame.minY + fold + 34 + CGFloat(line) * 34,
					width: width,
					height: 14
				),
				xRadius: 7,
				yRadius: 7
			).fill()
		}
		let label = CGRect(
			x: frame.minX - 26,
			y: frame.maxY - frame.height * 0.34,
			width: frame.width * 0.74,
			height: frame.height * 0.2
		)
		color(0xE5342B).setFill()
		NSBezierPath(roundedRect: label, xRadius: 16, yRadius: 16).fill()
		let text = centered(
			"PDF",
			font: .systemFont(ofSize: label.height * 0.62, weight: .heavy),
			color: .white,
			lineHeight: label.height
		)
		text.draw(with: label, options: .usesLineFragmentOrigin)
	}
}

func drawAccent(_ accent: Accent, screenshot: NSImage, screen: CGRect, device: CGRect) {
	let pixels = screen.width / screenshot.size.width
	switch accent {
	case let .paperAndPDF(letter):
		drawLetter(letter, in: CGRect(x: 0, y: device.minY - 110, width: 330, height: 467), degrees: -12)
		drawPDFMark(in: CGRect(x: 1060, y: device.minY - 250, width: 220, height: 282), degrees: 11)
	case let .callout(crop, cornerRadius, scale):
		let size = CGSize(width: crop.width * pixels * scale, height: crop.height * pixels * scale)
		let center = CGPoint(x: screen.minX + crop.midX * pixels, y: screen.minY + crop.midY * pixels)
		let frame = CGRect(
			x: center.x - size.width / 2,
			y: center.y - size.height / 2,
			width: size.width,
			height: size.height
		)
		let radius = cornerRadius * pixels * scale
		let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
		withShadow(blur: 80, offset: 30, alpha: 0.5) {
			NSColor.white.setFill()
			outline.fill()
		}
		NSGraphicsContext.saveGraphicsState()
		outline.addClip()
		let source = CGRect(x: crop.minX, y: screenshot.size.height - crop.maxY, width: crop.width, height: crop.height)
		screenshot.draw(
			in: frame,
			from: source,
			operation: .copy,
			fraction: 1,
			respectFlipped: true,
			hints: [.interpolation: NSImageInterpolation.high]
		)
		NSGraphicsContext.restoreGraphicsState()
		color(0xFFFFFF, alpha: 0.7).setStroke()
		outline.lineWidth = 3
		outline.stroke()
	case let .symbols(symbols):
		let tile: CGFloat = 190
		let gap: CGFloat = 44
		let row = CGFloat(symbols.count) * tile + CGFloat(symbols.count - 1) * gap
		for (index, item) in symbols.enumerated() {
			let frame = CGRect(
				x: (canvas.width - row) / 2 + CGFloat(index) * (tile + gap),
				y: device.minY - tile / 2 + 30,
				width: tile,
				height: tile
			)
			let outline = NSBezierPath(roundedRect: frame, xRadius: 48, yRadius: 48)
			withShadow(blur: 50, offset: 20, alpha: 0.4) {
				NSColor.white.setFill()
				outline.fill()
			}
			drawCentered(symbol(item.symbol, pointSize: 88, tint: color(item.tint)), in: frame.insetBy(dx: 44, dy: 44))
		}
	case let .pill(name, tint, text):
		let label = NSAttributedString(
			string: text,
			attributes: [.font: NSFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: NSColor.black]
		)
		let height: CGFloat = 150
		let circle: CGFloat = 108
		let width = 22 + circle + 30 + label.size().width + 56
		let frame = CGRect(
			x: (canvas.width - width) / 2,
			y: device.minY - height / 2 + 30,
			width: width,
			height: height
		)
		let outline = NSBezierPath(roundedRect: frame, xRadius: height / 2, yRadius: height / 2)
		withShadow(blur: 50, offset: 20, alpha: 0.4) {
			NSColor.white.setFill()
			outline.fill()
		}
		let disc = CGRect(x: frame.minX + 22, y: frame.midY - circle / 2, width: circle, height: circle)
		color(tint).setFill()
		NSBezierPath(ovalIn: disc).fill()
		drawCentered(symbol(name, pointSize: 52, tint: .white), in: disc.insetBy(dx: 22, dy: 22))
		label.draw(at: CGPoint(x: disc.maxX + 30, y: frame.midY - label.size().height / 2))
	}
}

/// App Store Connect refuses an image with an alpha channel, so the context skips it.
func compose(_ image: StoreImage, screenshot: NSImage, bezel: NSImage) -> NSBitmapImageRep {
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
	let headlineHeight = headline.boundingRect(
		with: CGSize(width: canvas.width - 160, height: 1000),
		options: .usesLineFragmentOrigin
	).height
	headline.draw(
		with: CGRect(x: 80, y: headlineTop, width: canvas.width - 160, height: headlineHeight),
		options: .usesLineFragmentOrigin
	)
	let sentence = centered(
		image.sentence,
		font: .systemFont(ofSize: 54, weight: .medium),
		color: sentenceColor,
		lineHeight: 68
	)
	let sentenceTop = headlineTop + headlineHeight + 36
	sentence.draw(
		with: CGRect(x: 80, y: sentenceTop, width: canvas.width - 160, height: 200),
		options: .usesLineFragmentOrigin
	)

	let pixels = screenWidth / 1320
	let frame = CGSize(width: bezelSize.width * pixels, height: bezelSize.height * pixels)
	let device = CGRect(
		x: (canvas.width - frame.width) / 2,
		y: canvas.height - deviceBottomMargin - frame.height,
		width: frame.width,
		height: frame.height
	)
	let screen = CGRect(
		x: device.minX + bezelScreenOrigin.x * pixels,
		y: device.minY + bezelScreenOrigin.y * pixels,
		width: screenWidth,
		height: screenWidth * screenshot.size.height / screenshot.size.width
	)
	let screenRadius = screenWidth * screenCornerShare

	let behind = if case .paperAndPDF = image.accent {
		true
	} else {
		false
	}
	if behind {
		drawAccent(image.accent, screenshot: screenshot, screen: screen, device: device)
	}

	// The bezel's screen is clear, so a filled outline casts the shadow and the screenshot shows through.
	withShadow(blur: 70, offset: 30, alpha: 0.45) {
		NSColor.black.setFill()
		NSBezierPath(
			roundedRect: device.insetBy(dx: 12 * pixels, dy: 12 * pixels),
			xRadius: screenRadius + 60 * pixels,
			yRadius: screenRadius + 60 * pixels
		).fill()
	}
	NSGraphicsContext.saveGraphicsState()
	NSBezierPath(roundedRect: screen, xRadius: screenRadius, yRadius: screenRadius).addClip()
	screenshot.draw(
		in: screen,
		from: .zero,
		operation: .copy,
		fraction: 1,
		respectFlipped: true,
		hints: [.interpolation: NSImageInterpolation.high]
	)
	NSGraphicsContext.restoreGraphicsState()
	bezel.draw(
		in: device,
		from: .zero,
		operation: .sourceOver,
		fraction: 1,
		respectFlipped: true,
		hints: [.interpolation: NSImageInterpolation.high]
	)

	if !behind {
		drawAccent(image.accent, screenshot: screenshot, screen: screen, device: device)
	}
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
let repository = application.deletingLastPathComponent().deletingLastPathComponent()
let input = application.appendingPathComponent("build/store_screenshots/\(appearance)")
let output = application.appendingPathComponent("build/store_images/\(appearance)")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

guard let bezel = NSImage(contentsOfFile: bezelPath) else {
	FileHandle.standardError.write(Data("""
	error: \(bezelPath) is missing; download Bezel-iPhone-17.dmg from
	https://developer.apple.com/design/resources/, accept its license, and copy the PNG there
	""".utf8 + [10]))
	exit(1)
}

bezel.size = bezelSize

for (index, image) in images.enumerated() {
	let source = input.appendingPathComponent("\(image.screenshot).png")
	guard let data = try? Data(contentsOf: source), let pixels = NSBitmapImageRep(data: data) else {
		FileHandle.standardError
			.write(Data("error: \(source.path) is missing; run capture_store_screenshots.sh first\n".utf8))
		exit(1)
	}
	// Sized in pixels, so a crop is given in the screenshot's pixels.
	let screenshot = NSImage(size: CGSize(width: pixels.pixelsWide, height: pixels.pixelsHigh))
	screenshot.addRepresentation(pixels)
	let composed = compose(image, screenshot: screenshot, bezel: bezel)
	let scene = image.screenshot.drop { $0 != "_" }.dropFirst()
	let name = String(format: "%02d_", index + 1) + scene + ".png"
	guard let png = composed.representation(using: .png, properties: [:]) else {
		fatalError("\(name) could not be encoded")
	}
	try png.write(to: output.appendingPathComponent(name))
}

print(output.path)
