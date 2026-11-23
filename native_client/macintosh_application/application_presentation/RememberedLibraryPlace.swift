import ApplicationBindings
import LibraryPresentation

/// The scope and the document the window showed last, which the next launch shows again.
public struct RememberedLibraryPlace: Equatable, Sendable {
	public let scope: LibraryScope
	public let scopeName: String?
	public let document: DocumentIdentifier?

	public init(scope: LibraryScope, scopeName: String?, document: DocumentIdentifier?) {
		self.scope = scope
		self.scopeName = scopeName
		self.document = document
	}

	/// The place a navigation shows, or nil on a page, which leaves the place remembered before. A
	/// sender's documents are a step that Back leaves, so the document is remembered in All Documents.
	public init?(_ navigation: LibraryNavigationState) {
		guard case let .library(scope, name) = navigation.destination else {
			return nil
		}
		if case .sender = scope {
			self.init(scope: .allDocuments, scopeName: nil, document: navigation.selectedDocument)
		} else {
			self.init(scope: scope, scopeName: name, document: navigation.selectedDocument)
		}
	}

	/// Whether the copy still holds the member, category, or tag the scope names.
	public func isHeld(by facets: LibraryFacets) -> Bool {
		let named: [ScopeCount]
		switch scope {
		case .member: named = facets.members
		case .category: named = facets.categories
		case .tag: named = facets.tags
		case .allDocuments, .recentlyAdded, .inIngestion, .failed, .household, .sender: return true
		}
		return named.contains { $0.scope.scope == scope }
	}

	/// Shows the place in a navigation that has not moved yet.
	public func restore(into navigation: inout LibraryNavigationState) {
		navigation.destination = .library(scope, title: scopeName)
		navigation.selectedDocument = document
	}

	/// The place as text values for the preferences.
	public var storedValues: [String: String] {
		var values = ["scope": Self.kind(of: scope)]
		values["identifier"] = Self.identifier(of: scope)
		values["name"] = scopeName
		values["document"] = document?.value
		return values
	}

	/// The place stored values describe, or nil for values of another version.
	public init?(storedValues values: [String: String]) {
		let identifier = values["identifier"]
		let scope: LibraryScope? = switch (values["scope"], identifier) {
		case ("allDocuments", _): .allDocuments
		case ("recentlyAdded", _): .recentlyAdded
		case ("inIngestion", _): .inIngestion
		case ("failed", _): .failed
		case ("household", _): .household
		case let ("member", value?): .member(member: MemberIdentifier(value: value))
		case let ("category", value?): .category(category: CategoryIdentifier(value: value))
		case let ("tag", value?): .tag(tag: TagIdentifier(value: value))
		default: nil
		}
		guard let scope else {
			return nil
		}
		self.init(
			scope: scope,
			scopeName: values["name"],
			document: values["document"].map { DocumentIdentifier(value: $0) }
		)
	}

	private static func kind(of scope: LibraryScope) -> String {
		switch scope {
		case .allDocuments: "allDocuments"
		case .recentlyAdded: "recentlyAdded"
		case .inIngestion: "inIngestion"
		case .failed: "failed"
		case .household: "household"
		case .member: "member"
		case .category: "category"
		case .tag: "tag"
		case .sender: "sender"
		}
	}

	private static func identifier(of scope: LibraryScope) -> String? {
		switch scope {
		case let .member(member): member.value
		case let .category(category): category.value
		case let .tag(tag): tag.value
		case let .sender(sender): sender.value
		case .allDocuments, .recentlyAdded, .inIngestion, .failed, .household: nil
		}
	}
}
