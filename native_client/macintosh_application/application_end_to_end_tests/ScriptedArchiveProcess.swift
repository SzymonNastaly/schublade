import CryptoKit
import Darwin
import Foundation
import XCTest

/// Manages a local `scripted-archive-server` child process for end-to-end tests.
final class ScriptedArchiveProcess {
	let baseURL: URL
	private let process: Process
	private let standardInputPipe: Pipe

	private init(baseURL: URL, process: Process, standardInputPipe: Pipe) {
		self.baseURL = baseURL
		self.process = process
		self.standardInputPipe = standardInputPipe
	}

	@concurrent
	static func start(token: String, seedCount: Int) async throws -> sending ScriptedArchiveProcess {
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

		let standardInputPipe = Pipe()
		let standardOutputPipe = Pipe()
		process.standardInput = standardInputPipe
		process.standardOutput = standardOutputPipe

		try process.run()

		let buffer = readFirstLine(
			from: standardOutputPipe.fileHandleForReading,
			deadline: ContinuousClock.now + .seconds(10)
		)
		let prefix = "listening "
		guard
			let line = String(bytes: buffer, encoding: .utf8),
			line.hasPrefix(prefix),
			let baseURL = URL(string: String(line.dropFirst(prefix.count)))
		else {
			process.terminate()
			process.waitUntilExit()
			let detail = String(bytes: buffer, encoding: .utf8) ?? "<non-utf8>"
			throw ConditionNotReached(expectation: "scripted-archive-server listening line", detail: detail)
		}

		return ScriptedArchiveProcess(
			baseURL: baseURL,
			process: process,
			standardInputPipe: standardInputPipe
		)
	}

	func seedDocument(_ document: SeededDocument) async throws {
		var request = URLRequest(url: baseURL.appending(path: "scripted/documents"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(document)
		let (_, response) = try await URLSession.shared.data(for: request)
		let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
		guard httpResponse.statusCode == 200 else {
			throw ConditionNotReached(
				expectation: "POST /scripted/documents status 200",
				detail: "status \(httpResponse.statusCode)"
			)
		}
	}

	/// The text the archive holds for the document of a file's bytes, read through the lookup and the
	/// text route as a client of the archive reads it.
	func text(ofDocumentHolding file: URL, token: String) async throws -> String {
		let digest = try SHA256.hash(data: Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
		var lookup = URLRequest(url: baseURL.appending(path: "api/v1/contents/lookup"))
		lookup.httpMethod = "POST"
		lookup.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		lookup.setValue("application/json", forHTTPHeaderField: "Content-Type")
		lookup.httpBody = try JSONEncoder().encode(["sha256": [digest]])
		let (answer, _) = try await URLSession.shared.data(for: lookup)
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		let document = try XCTUnwrap(decoder.decode(ContentLookupAnswer.self, from: answer).contents.first?.documentId)
		var textRequest = URLRequest(url: baseURL.appending(path: "api/v1/documents/\(document)/text"))
		textRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		let (text, _) = try await URLSession.shared.data(for: textRequest)
		return try XCTUnwrap(String(bytes: text, encoding: .utf8))
	}

	func stop() {
		try? standardInputPipe.fileHandleForWriting.close()
		if process.isRunning {
			process.terminate()
		}
		process.waitUntilExit()
	}

	private static func readFirstLine(from fileHandle: FileHandle, deadline: ContinuousClock.Instant) -> Data {
		let descriptor = fileHandle.fileDescriptor
		var descriptorEntry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
		var buffer = Data()
		var byteBuffer: UInt8 = 0

		while ContinuousClock.now < deadline {
			let remaining = ContinuousClock.now.duration(to: deadline)
			let totalMilliseconds = remaining.components.seconds * 1000
				+ remaining.components.attoseconds / 1_000_000_000_000_000
			let timeoutMilliseconds = Int32(min(max(totalMilliseconds, 1), 10000))
			descriptorEntry.revents = 0
			let ready = Darwin.poll(&descriptorEntry, 1, timeoutMilliseconds)
			if ready == 0 {
				break
			}
			if ready < 0 {
				if errno == EINTR {
					continue
				}
				break
			}
			let bytesRead = Darwin.read(descriptor, &byteBuffer, 1)
			if bytesRead <= 0 || byteBuffer == 0x0A {
				break
			}
			buffer.append(byteBuffer)
		}
		return buffer
	}

	private static func resolveServerBinary() throws -> URL {
		if let configured = ProcessInfo.processInfo.environment["SCHUBLADE_SCRIPTED_ARCHIVE_SERVER"] {
			let candidate = URL(fileURLWithPath: configured)
			guard FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) else {
				throw ConditionNotReached(
					expectation: "executable at SCHUBLADE_SCRIPTED_ARCHIVE_SERVER",
					detail: configured
				)
			}
			return candidate
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

/// `POST /api/v1/contents/lookup` answered for one digest.
private struct ContentLookupAnswer: Decodable {
	let contents: [LookedUpContent]
}

private struct LookedUpContent: Decodable {
	let documentId: String?
}
