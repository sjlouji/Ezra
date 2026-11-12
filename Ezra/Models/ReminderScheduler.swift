import Foundation
@preconcurrency import UserNotifications

/// Keeps one pending notification per task that has a future reminder.
@MainActor
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderScheduler()

    override private init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let snoozes = Self.snoozes.map { UNNotificationAction(identifier: $0.id, title: $0.title) }
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: snoozes, intentIdentifiers: [])])
    }

    func sync(_ task: ToDo) {
        cancel(task.uuid)
        guard let fireDate = task.reminderAt, !task.isCompleted, fireDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = task.title
        if let project = task.project?.name {
            content.subtitle = project
        }
        content.sound = .default
        content.categoryIdentifier = Self.category
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let request = UNNotificationRequest(
            identifier: task.uuid.uuidString,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )

        Task {
            do {
                let center = UNUserNotificationCenter.current()
                // Once notifications are switched off for the app, macOS refuses every request; only System Settings turns them back on.
                guard await center.notificationSettings().authorizationStatus != .denied,
                      try await center.requestAuthorization(options: [.alert, .sound])
                else { return Self.reportBlocked() }
                try await center.add(request)
                Log.reminders.info("Scheduled reminder \(request.identifier, privacy: .public)")
            } catch let error as UNError where error.code == .notificationsNotAllowed {
                Self.reportBlocked()
            } catch {
                Alerts.shared.report("schedule the reminder", error)
            }
        }
    }

    private static func reportBlocked() {
        Log.reminders.warning("Notifications are blocked for the app; reminder saved but not scheduled")
        if let settings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.ezra.Ezra") {
            Alerts.shared.settingsLink = ("Open Notification Settings", settings)
        }
        Alerts.shared.message =
            "The reminder is saved, but macOS is blocking \(Brand.name)'s notifications. Turn on “Allow notifications” for \(Brand.name) in System Settings › Notifications, then set the reminder again."
    }

    func cancel(_ taskID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [taskID.uuidString])
    }

    private static let category = "reminder"
    /// The ways a reminder can be put off, as offered on the notification.
    private static let snoozes: [(id: String, title: String, seconds: TimeInterval)] = [
        ("snooze.15m", "Remind Me in 15 Minutes", 900), ("snooze.1h", "Remind Me in 1 Hour", 3600),
        ("snooze.3h", "Remind Me in 3 Hours", 10800), ("snooze.1d", "Remind Me Tomorrow", 86400),
    ]

    /// A snooze button on a reminder moves that to-do's reminder forward.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let (action, identifier) = (response.actionIdentifier, response.notification.request.identifier)
        await MainActor.run {
            guard let snooze = Self.snoozes.first(where: { $0.id == action }), let id = UUID(uuidString: identifier),
                  let container = EzraStore.shared
            else { return }
            Alerts.shared.attempt("snooze the reminder") {
                let workspace = Workspace(context: container.mainContext)
                guard let todo = try workspace.todo(withID: id) else { return }
                try workspace.setReminder(todo, at: Date.now.addingTimeInterval(snooze.seconds))
            }
        }
    }

    /// Show the reminder even while the app is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
