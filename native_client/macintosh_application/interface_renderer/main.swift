import AppKit
import Foundation

func argumentValue(after flag: String, in arguments: [String]) -> String? {
	guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
		return nil
	}
	return arguments[index + 1]
}

let arguments = CommandLine.arguments
let outputPath = argumentValue(after: "--output", in: arguments) ?? "build/rendered_interface"
let fixturesPath = argumentValue(after: "--fixtures", in: arguments) ?? "../../test_fixtures/documents"

let outputURL = URL(filePath: outputPath, directoryHint: .isDirectory)
let fixturesURL = URL(filePath: fixturesPath, directoryHint: .isDirectory)
let temporaryURL = URL.temporaryDirectory.appending(
	path: "schublade_renderer_\(UUID().uuidString)",
	directoryHint: .isDirectory
)

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
defer {
	try? FileManager.default.removeItem(at: temporaryURL)
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
/// The welcome shows the application's icon, which a command-line tool lacks, so the renderer takes
/// the icon of the application built beside it.
let builtApplication = try FileManager.default.contentsOfDirectory(
	at: URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent(),
	includingPropertiesForKeys: nil
).first { $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("Schublade") }
if let builtApplication {
	application.applicationIconImage = NSWorkspace.shared.icon(forFile: builtApplication.path)
}

let fixtures = RendererFixtures(fixturesDirectory: fixturesURL, temporaryDirectory: temporaryURL)
let renderer = ScreenRenderer(outputDirectory: outputURL, fixtures: fixtures)
try await renderer.renderAllScreens()
try await StatusItemRenderer(outputDirectory: outputURL, fixtures: fixtures).renderAll()
