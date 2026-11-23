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

	/// Follows a collector status. Permission is asked when a folder is added, never at launch;
	/// nothing is posted while the window has the person's attention, because it shows the same;
	/// and a notification whose event is over is withdrawn.
	func observe(_ status: CollectorStatus, context: ApplicationWordingContext, windowAttended: Bool) {
		let notices = CollectorNotices.arising(previous: previous, next: status, context: context)
		let settled = CollectorNotices.settled(previous: previous, next: status)
		let folderAdded = status.folders.count > (previous?.folders.count ?? status.folders.count)
		previous = status
		guard isEnabled else {
			return
		}
		let center = UNUserNotificationCenter.current()
		if !settled.isEmpty {
			center.removeDeliveredNotifications(withIdentifiers: settled)
		}
		if folderAdded {
			Task {
				_ = try? await center.requestAuthorization(options: [.alert, .sound])
			}
		}
		guard !notices.isEmpty, !windowAttended else {
			return
		}
		Task {
			guard await center.notificationSettings().authorizationStatus == .authorized else {
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
