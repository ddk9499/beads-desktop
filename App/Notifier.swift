import AppKit
import BeadsKit
import Foundation
import UserNotifications

/// Posts macOS notifications for changes found by a background refresh, and routes clicks back to the app.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called with (project id, issue id) when the user clicks a notification.
    var onOpen: ((UUID, String?) -> Void)?

    /// Above this many changes in one refresh, a single summary notification is posted.
    static let summaryThreshold = 4

    private var center: UNUserNotificationCenter { .current() }

    func activate() {
        center.delegate = self
    }

    /// Last authorization problem, shown in Settings (nil when fine).
    private(set) var authorizationError: String?

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        log("authorization status: \(settings.authorizationStatus.rawValue)")
        guard settings.authorizationStatus == .notDetermined else { return }
        await requestAuthorization()
    }

    /// Asks macOS for permission (shows the system prompt when the status is not determined yet).
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorizationError = nil
            log("requestAuthorization granted=\(granted)")
            return granted
        } catch {
            authorizationError = "\(error.localizedDescription) (\(error))"
            log("requestAuthorization failed: \(error)")
            return false
        }
    }

    private func log(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[notifier] \(message)\n".utf8))
        #endif
    }

    func post(_ changes: [IssueChange], project: Project) {
        let enabled = NotificationPrefs.enabledKinds()
        let relevant = changes.filter { enabled.contains($0.kind) }
        #if DEBUG
        FileHandle.standardError.write(Data("[notifier] \(project.displayName): \(changes.map(\.summary)) → notify \(relevant.count)\n".utf8))
        #endif
        guard !relevant.isEmpty else { return }

        if relevant.count > Self.summaryThreshold {
            let content = UNMutableNotificationContent()
            content.title = project.displayName
            content.subtitle = "\(relevant.count) changes"
            content.body = relevant.prefix(3).map(\.summary).joined(separator: "\n")
                + (relevant.count > 3 ? "\n…" : "")
            content.userInfo = ["project": project.id.uuidString]
            content.threadIdentifier = project.id.uuidString
            add(content, id: "\(project.id)-summary-\(Date.now.timeIntervalSince1970)")
            return
        }
        for change in relevant {
            let content = UNMutableNotificationContent()
            content.title = project.displayName
            content.subtitle = Self.title(for: change)
            content.body = "\(change.issue.id) · \(change.issue.title)"
            content.userInfo = ["project": project.id.uuidString, "issue": change.issue.id]
            content.threadIdentifier = project.id.uuidString
            add(content, id: "\(project.id)-\(change.id)-\(change.issue.updatedAt?.timeIntervalSince1970 ?? 0)")
        }
    }

    static func title(for change: IssueChange) -> String {
        switch change.kind {
        case .created: "New issue"
        case .closed: "Closed"
        case .reopened: "Reopened"
        case .unblocked: "Unblocked — ready to pick up"
        case .becameBlocked: "Blocked"
        case .moved: "\(change.from?.title ?? "—") → \(change.to?.title ?? "—")"
        case .reassigned: "Assigned to \(change.issue.assignee ?? "nobody")"
        }
    }

    private func add(_ content: UNMutableNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        // While the app is in front, the board's change highlights are enough.
        await NSApplication.shared.isActive ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["project"] as? String, let projectID = UUID(uuidString: raw) else { return }
        let issue = info["issue"] as? String
        await MainActor.run {
            NSApplication.shared.activate()
            onOpen?(projectID, issue)
        }
    }
}

/// Which change kinds produce notifications (Settings → Notifications).
enum NotificationPrefs {
    static let defaults: [IssueChange.Kind: Bool] = [
        .closed: true, .unblocked: true, .created: false, .becameBlocked: false,
        .reopened: false, .moved: false, .reassigned: false,
    ]

    static func key(_ kind: IssueChange.Kind) -> String { "notify.\(kind.rawValue)" }

    static func enabledKinds() -> Set<IssueChange.Kind> {
        let store = UserDefaults.standard
        return Set(IssueChange.Kind.allCases.filter { kind in
            store.object(forKey: key(kind)) as? Bool ?? defaults[kind] ?? false
        })
    }

    static func label(_ kind: IssueChange.Kind) -> String {
        switch kind {
        case .created: "New issues"
        case .closed: "Issues closed"
        case .reopened: "Issues reopened"
        case .unblocked: "Issues unblocked"
        case .becameBlocked: "Issues became blocked"
        case .moved: "Other column moves (e.g. picked up)"
        case .reassigned: "Assignee changes"
        }
    }
}
