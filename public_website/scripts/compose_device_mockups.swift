// Composes the website's mock-ups of the iPhone and Mac applications: each screenshot of
// src/assets/screenshots inside Apple's product bezel, with a transparent surround, written to
// src/assets/device_mockups/<name>.png. The web app runs on every platform, so its screenshots get
// the website's own CSS frames instead and never an Apple bezel.
//   scripts/execute_on_macintosh.sh swift public_website/scripts/compose_device_mockups.swift
//   scp 'mac:schublade/public_website/src/assets/device_mockups/*.png' public_website/src/assets/device_mockups/
// The bezels come from Bezel-iPhone-17.dmg and Bezel-MacBook-Pro-M5.dmg of
// https://developer.apple.com/design/resources/ into ~/apple_design_resources on the Mac. Their
// license allows mock-ups of software that runs only on Apple's platforms, and not the bezels
// themselves in this repository.
import AppKit

struct Device {
	let bezelFile: String
	let bezelSize: CGSize
	/// The clear screen of the bezel, in its pixels.
	let screen: CGRect
	let screenCornerRadius: CGFloat
	/// The share of the bezel's pixels that the written mock-up keeps.
	let outputScale: CGFloat
}

let iphone = Device(
	bezelFile: "iPhone 17 Pro Max - Silver - Portrait.png",
	bezelSize: CGSize(width: 1470, height: 3000),
	screen: CGRect(x: 75, y: 66, width: 1320, height: 2868),
	screenCornerRadius: 186,
	outputScale: 0.5
)

let macbook = Device(
	bezelFile: "MacBook Pro M5 14-inch Silver.png",
	bezelSize: CGSize(width: 3860, height: 2540),
	screen: CGRect(x: 418, y: 288, width: 3024, height: 1964),
	screenCornerRadius: 38,
	outputScale: 0.6
)

enum Placement {
	/// The screenshot fills the screen.
	case fullScreen
	/// The screenshot is a window on a desktop below the menu bar.
	case desktopWindow
}

let mockups: [(screenshot: String, device: Device, placement: Placement)] = [
	("iphone_library_arriving", iphone, .fullScreen),
	("iphone_search_category", iphone, .fullScreen),
	("iphone_document_details", iphone, .fullScreen),
	("iphone_share_sheet", iphone, .fullScreen),
	("iphone_scan_shortcuts", iphone, .fullScreen),
	("mac_library_reader", macbook, .desktopWindow),
	("mac_text_search", macbook, .desktopWindow),
]

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
	NSColor(
		srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
		green: CGFloat((hex >> 8) & 0xFF) / 255,
		blue: CGFloat(hex & 0xFF) / 255,
		alpha: alpha
	)
}

/// The menu bar of a MacBook with a camera housing, 37 points tall at 2x.
let menuBarHeight: CGFloat = 74
let windowCornerRadius: CGFloat = 32

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage {
	let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
		.applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
	guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
		.withSymbolConfiguration(configuration)
	else {
		fatalError("The symbol \(name) is missing")
	}
	return image
}

/// The application's menus as MainMenuBuilder names them, on the left of the menu bar, and the
/// status items and the clock on its right.
func drawMenuBar(in screen: CGRect) {
	let baseline = screen.minY + menuBarHeight / 2
	let font = NSFont.systemFont(ofSize: 27, weight: .regular)
	var x = screen.minX + 40
	let apple = symbol("apple.logo", pointSize: 30, weight: .medium)
	apple.draw(in: CGRect(
		x: x,
		y: baseline - apple.size.height / 2 - 2,
		width: apple.size.width,
		height: apple.size.height
	))
	x += apple.size.width + 44
	for (index, title) in ["Schublade", "File", "Edit", "View", "Window", "Help"].enumerated() {
		let label = NSAttributedString(string: title, attributes: [
			.font: index == 0 ? NSFont.systemFont(ofSize: 27, weight: .bold) : font,
			.foregroundColor: NSColor.white,
		])
		label.draw(at: CGPoint(x: x, y: baseline - label.size().height / 2))
		x += label.size().width + 40
	}
	let clock = NSAttributedString(string: "Wed 25 Nov  9:41", attributes: [
		.font: font,
		.foregroundColor: NSColor.white,
	])
	var right = screen.maxX - 40 - clock.size().width
	clock.draw(at: CGPoint(x: right, y: baseline - clock.size().height / 2))
	for name in ["switch.2", "magnifyingglass", "wifi", "battery.100percent"] {
		let image = symbol(name, pointSize: 26)
		right -= image.size.width + 34
		image.draw(in: CGRect(
			x: right,
			y: baseline - image.size.height / 2,
			width: image.size.width,
			height: image.size.height
		))
	}
}

/// The icon's blue as the desktop picture, lighter where the light falls in from the top left.
func drawDesktop(in screen: CGRect) {
	NSGradient(colors: [color(0x2C68C4), color(0x1A4FA6), color(0x123F8C)])?.draw(in: screen, angle: -70)
	NSGradient(colors: [color(0xCDE4FF, alpha: 0.42), color(0xCDE4FF, alpha: 0)])?.draw(
		fromCenter: CGPoint(x: screen.minX + screen.width * 0.25, y: screen.minY),
		radius: 0,
		toCenter: CGPoint(x: screen.minX + screen.width * 0.25, y: screen.minY),
		radius: screen.width * 0.7,
		options: []
	)
}

func drawWindow(_ screenshot: NSImage, in screen: CGRect) {
	let desktop = CGRect(
		x: screen.minX,
		y: screen.minY + menuBarHeight,
		width: screen.width,
		height: screen.height - menuBarHeight
	)
	let frame = CGRect(
		x: desktop.midX - screenshot.size.width / 2,
		y: desktop.midY - screenshot.size.height / 2,
		width: screenshot.size.width,
		height: screenshot.size.height
	)
	let outline = NSBezierPath(roundedRect: frame, xRadius: windowCornerRadius, yRadius: windowCornerRadius)
	NSGraphicsContext.saveGraphicsState()
	let shadow = NSShadow()
	shadow.shadowColor = color(0x061A3D, alpha: 0.55)
	shadow.shadowBlurRadius = 90
	shadow.shadowOffset = CGSize(width: 0, height: 36)
	shadow.set()
	NSColor.white.setFill()
	outline.fill()
	NSGraphicsContext.restoreGraphicsState()

	NSGraphicsContext.saveGraphicsState()
	outline.addClip()
	screenshot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
	NSGraphicsContext.restoreGraphicsState()
	color(0x000000, alpha: 0.28).setStroke()
	let edge = NSBezierPath(
		roundedRect: frame.insetBy(dx: 1, dy: 1),
		xRadius: windowCornerRadius - 1,
		yRadius: windowCornerRadius - 1
	)
	edge.lineWidth = 2
	edge.stroke()
}

func compose(_ screenshot: NSImage, on device: Device, placement: Placement, bezel: NSImage) -> NSBitmapImageRep {
	let size = device.bezelSize
	guard let context = CGContext(
		data: nil,
		width: Int(size.width),
		height: Int(size.height),
		bitsPerComponent: 8,
		bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB)!,
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
	) else {
		fatalError("A bitmap of \(size) could not be made")
	}
	context.translateBy(x: 0, y: size.height)
	context.scaleBy(x: 1, y: -1)
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

	NSGraphicsContext.saveGraphicsState()
	NSBezierPath(
		roundedRect: device.screen,
		xRadius: device.screenCornerRadius,
		yRadius: device.screenCornerRadius
	).addClip()
	switch placement {
	case .fullScreen:
		screenshot.draw(
			in: device.screen,
			from: .zero,
			operation: .copy,
			fraction: 1,
			respectFlipped: true,
			hints: [.interpolation: NSImageInterpolation.high]
		)
	case .desktopWindow:
		drawDesktop(in: device.screen)
		drawWindow(screenshot, in: device.screen)
		drawMenuBar(in: device.screen)
	}
	NSGraphicsContext.restoreGraphicsState()
	bezel.draw(
		in: CGRect(origin: .zero, size: size),
		from: .zero,
		operation: .sourceOver,
		fraction: 1,
		respectFlipped: true,
		hints: [.interpolation: NSImageInterpolation.high]
	)
	NSGraphicsContext.restoreGraphicsState()
	guard let full = context.makeImage() else {
		fatalError("The bitmap could not be read")
	}

	let output = CGSize(width: (size.width * device.outputScale).rounded(), height: (size.height * device.outputScale).rounded())
	guard let reduced = CGContext(
		data: nil,
		width: Int(output.width),
		height: Int(output.height),
		bitsPerComponent: 8,
		bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB)!,
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
	) else {
		fatalError("A bitmap of \(output) could not be made")
	}
	reduced.interpolationQuality = .high
	reduced.draw(full, in: CGRect(origin: .zero, size: output))
	guard let picture = reduced.makeImage() else {
		fatalError("The reduced bitmap could not be read")
	}
	return NSBitmapImageRep(cgImage: picture)
}

let website = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let input = website.appendingPathComponent("src/assets/screenshots")
let output = website.appendingPathComponent("src/assets/device_mockups")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let resources = NSString(string: "~/apple_design_resources").expandingTildeInPath

for mockup in mockups {
	let bezelPath = "\(resources)/\(mockup.device.bezelFile)"
	guard let bezel = NSImage(contentsOfFile: bezelPath) else {
		FileHandle.standardError.write(Data("""
		error: \(bezelPath) is missing; download the bezel from
		https://developer.apple.com/design/resources/, accept its license, and copy the PNG there
		""".utf8 + [10]))
		exit(1)
	}
	bezel.size = mockup.device.bezelSize
	let source = input.appendingPathComponent("\(mockup.screenshot).png")
	guard let data = try? Data(contentsOf: source), let pixels = NSBitmapImageRep(data: data) else {
		FileHandle.standardError.write(Data("error: \(source.path) is missing\n".utf8))
		exit(1)
	}
	let screenshot = NSImage(size: CGSize(width: pixels.pixelsWide, height: pixels.pixelsHigh))
	screenshot.addRepresentation(pixels)
	let composed = compose(screenshot, on: mockup.device, placement: mockup.placement, bezel: bezel)
	guard let png = composed.representation(using: .png, properties: [:]) else {
		fatalError("\(mockup.screenshot) could not be encoded")
	}
	try png.write(to: output.appendingPathComponent("\(mockup.screenshot).png"))
}

print(output.path)
