import Foundation
import LibraryPresentation

/// The library's wording context and the localized names of collected folders, injected into the
/// Mac's wording so tests and offscreen renders produce deterministic text.
public struct ApplicationWordingContext: Sendable {
	public let library: WordingContext
	public let folderName: @Sendable (String) -> String

	public init(library: WordingContext, folderName: @escaping @Sendable (String) -> String) {
		self.library = library
		self.folderName = folderName
	}

	public static func current(
		folderName: @escaping @Sendable (String) -> String = { path in
			FileManager().displayName(atPath: path)
		}
	) -> ApplicationWordingContext {
		ApplicationWordingContext(library: .current(), folderName: folderName)
	}
}
