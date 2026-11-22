import Foundation
import XCTest

struct SeededDocument: Encodable {
	let identifier: String
	let title: String
	let documentDate: String
	let senderName: String
	let categoryName: String
	let summary: String

	enum CodingKeys: String, CodingKey {
		case identifier
		case title
		case documentDate = "document_date"
		case senderName = "sender_name"
		case categoryName = "category_name"
		case summary
	}
}

struct ConditionNotReached: Error, CustomStringConvertible {
	let expectation: String
	let detail: String

	var description: String {
		"Timed out waiting for \(expectation): \(detail)"
	}
}

/// Manages a local `scripted-archive-server` child process for end-to-end tests.
final class ScriptedArchiveProcess {
	let baseURL: URL
	private let process: Process
	private let stdinPipe: Pipe

	private init(baseURL: URL, process: Process, stdinPipe: Pipe) {
		self.baseURL = baseURL
		self.process = process
		self.stdinPipe = stdinPipe
	}

	static func start(token: String, seedCount: Int) throws -> ScriptedArchiveProcess {
		let binaryURL = try resolveServerBinary()
		let process = Process()
		process.executableURL = binaryURL
		process.arguments = [
			"--token",
			token,
			"--permission",
			"read",
			"--seed",
			String(seedCount),
		]

		let stdinPipe = Pipe()
		let stdoutPipe = Pipe()
		process.standardInput = stdinPipe
		process.standardOutput = stdoutPipe

		try process.run()

		let reader = stdoutPipe.fileHandleForReading
		var buffer = Data()
		while let byte = try reader.read(upToCount: 1), !byte.isEmpty {
			if byte[0] == 0x0A {
				break
			}
			buffer.append(byte)
		}

		let prefix = "listening "
		guard
			let line = String(bytes: buffer, encoding: .utf8),
			line.hasPrefix(prefix),
			let baseURL = URL(string: String(line.dropFirst(prefix.count)))
		else {
			process.terminate()
			let detail = String(bytes: buffer, encoding: .utf8) ?? "<non-utf8>"
			throw ConditionNotReached(expectation: "scripted-archive-server listening line", detail: detail)
		}

		return ScriptedArchiveProcess(baseURL: baseURL, process: process, stdinPipe: stdinPipe)
	}

	func seedDocument(_ document: SeededDocument) async throws {
		var request = URLRequest(url: baseURL.appending(path: "scripted/documents"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(document)
		let (_, response) = try await URLSession.shared.data(for: request)
		let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
		XCTAssertEqual(httpResponse.statusCode, 200)
	}

	func stop() {
		try? stdinPipe.fileHandleForWriting.close()
		if process.isRunning {
			process.terminate()
		}
		process.waitUntilExit()
	}

	private static func resolveServerBinary() throws -> URL {
		if let configured = ProcessInfo.processInfo.environment["SCHUBLADE_SCRIPTED_ARCHIVE_SERVER"] {
			let candidate = URL(fileURLWithPath: configured)
			if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
				return candidate
			}
		}

		let workspaceRoot = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let candidates = [
			workspaceRoot.appending(path: "target/debug/scripted-archive-server"),
			workspaceRoot.appending(path: "target/aarch64-apple-darwin/debug/scripted-archive-server"),
		]
		let match = candidates.first { candidate in
			FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false))
		}
		if let match {
			return match
		}
		throw ConditionNotReached(
			expectation: "scripted-archive-server executable",
			detail: candidates.map { $0.path(percentEncoded: false) }.joined(separator: ", ")
		)
	}
}
