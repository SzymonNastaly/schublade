import AppKit
import ApplicationBindings
import ApplicationPresentation
import UserNotifications

/// Tells a person, through Notification Center, what only they can settle while the window is
/// closed: a folder whose survey finished, and a token the archive refused. A click opens the
/// window on the page that settles it. Statuses decide what to say in `CollectorNotices`.
final class CollectorNotifier: NSObject, UNUserNotificationCenterDelegate {
	nonisolated static let actionKey = "schublade.notice.action"
	nonisolated static let folderKey = "schublade.notice.folder"

	private let isEnabled: Bool
	private var previous: CollectorStatus?
	var onOpen: ((AttentionAction) -> Void)?

	/// A notifier that is not enabled only remembers statuses, so the isolated test environment never
	/// asks the system for permission.
	init(isEnabled: Bool) {
		self.isEnabled = isEnabled
		super.init()
		if isEnabled {
			UNUserNotificationCenter.current().delegate = self
		}
	}

	func observe(_ status: CollectorStatus, context: WordingContext) {
		let notices = CollectorNotices.arising(previous: previous, next: status, context: context)
		previous = status
		guard isEnabled, !notices.isEmpty else {
			return
		}
		Task {
			let center = UNUserNotificationCenter.current()
			guard await (try? center.requestAuthorization(options: [.alert, .sound])) == true else {
				return
			}
			for notice in notices {
				try? await center.add(Self.request(for: notice))
			}
		}
	}

	nonisolated func userNotificationCenter(
		_: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse
	) async {
		let information = response.notification.request.content.userInfo
		let action: AttentionAction? = switch information[Self.actionKey] as? String {
		case "replaceToken":
			.replaceToken
		case "decideBacklog":
			(information[Self.folderKey] as? Int64).map { .decideBacklog(FolderIdentifier(value: $0)) }
		default:
			nil
		}
		guard let action else {
			return
		}
		await MainActor.run {
			onOpen?(action)
		}
	}

	nonisolated func userNotificationCenter(
		_: UNUserNotificationCenter,
		willPresent _: UNNotification
	) async -> UNNotificationPresentationOptions {
		[.banner, .sound]
	}

	private static func request(for notice: CollectorNotice) -> UNNotificationRequest {
		let content = UNMutableNotificationContent()
		content.title = notice.title
		content.body = notice.body
		content.sound = .default
		switch notice.action {
		case .replaceToken:
			content.userInfo = [actionKey: "replaceToken"]
		case let .decideBacklog(folder), let .openFolder(folder):
			content.userInfo = [actionKey: "decideBacklog", folderKey: folder.value]
		}
		return UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
	}
}
