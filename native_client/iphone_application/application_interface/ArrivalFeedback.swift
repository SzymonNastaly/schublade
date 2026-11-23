import Foundation
import UIKit

/// What a person feels and hears of an arrival: a row appears, a letter is filed, the archive
/// refuses one. It compares each list of arrivals with the one before.
struct ArrivalFeedback {
	private var shown: [UUID: Arrival] = [:]

	/// Plays the feedback of `arrivals`, and answers whether a new arrival appeared, which brings the
	/// list to its top. A filing or a refusal is felt and announced only while the scene is active,
	/// and only for a row the person saw change.
	mutating func follow(_ arrivals: [Arrival], sceneActive: Bool) -> Bool {
		let previous = shown
		shown = Dictionary(arrivals.map { ($0.id, $0) }) { first, _ in first }
		let appeared = arrivals.contains { $0.stage == .preparing && previous[$0.id] == nil }
		if appeared {
			Haptics.arrivalAppeared()
		}
		guard sceneActive else {
			return appeared
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
		return appeared
	}
}
