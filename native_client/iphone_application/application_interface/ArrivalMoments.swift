import Foundation
import UIKit

/// The moments of an arrival that a person feels: a row lands, a letter is filed, the archive
/// refuses one. It compares each list of arrivals with the one before.
struct ArrivalMoments {
	private var shown: [UUID: Arrival] = [:]

	/// Plays the moments of `arrivals`, and answers whether a new arrival landed, which brings the
	/// list to its top. A filing or a refusal is felt and announced only while the scene is active,
	/// and only for a row the person saw change.
	mutating func follow(_ arrivals: [Arrival], sceneActive: Bool) -> Bool {
		let previous = shown
		shown = Dictionary(arrivals.map { ($0.id, $0) }) { first, _ in first }
		let landed = arrivals.contains { $0.stage == .preparing && previous[$0.id] == nil }
		if landed {
			Haptics.arrivalLanded()
		}
		guard sceneActive else {
			return landed
		}
		var filed: [String] = []
		var refused = false
		for arrival in arrivals {
			guard let before = previous[arrival.id]?.stage, before != arrival.stage else {
				continue
			}
			switch (before, arrival.stage) {
			case (.filed, _), (.notAccepted, _), (.tokenRefused, _):
				continue
			case let (_, .filed(document)):
				filed.append(document.title)
			case (_, .notAccepted), (_, .tokenRefused):
				refused = true
			default:
				continue
			}
		}
		if !filed.isEmpty {
			Haptics.arrivalFiled()
			UIAccessibility.post(
				notification: .announcement,
				argument: "Archived as \(ListFormatter.localizedString(byJoining: filed))"
			)
		} else if refused {
			Haptics.arrivalRefused()
		}
		return landed
	}
}
