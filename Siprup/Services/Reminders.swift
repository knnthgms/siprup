import Foundation
import SwiftData
import UserNotifications

/// Pure scheduling maths, kept separate so it can be unit tested.
enum ReminderPlan {
    /// Minutes-of-day for reminders between the end of quiet hours and the start of the next.
    static func minutesOfDay(intervalMinutes: Int, quietStart: Int, quietEnd: Int) -> [Int] {
        guard intervalMinutes > 0 else { return [] }
        let window = (quietStart - quietEnd + 1440) % 1440
        let awake = window == 0 ? 1440 : window
        var result: [Int] = []
        var offset = intervalMinutes
        while offset < awake {
            result.append((quietEnd + offset) % 1440)
            offset += intervalMinutes
        }
        return result
    }

    /// Concrete fire dates over the next few days, skipping the past, paused time,
    /// and the rest of today once today's goal is reached.
    static func fireDates(
        now: Date,
        minutes: [Int],
        days: Int = 3,
        pausedUntil: Date?,
        goalMetToday: Bool,
        clock: DayClock,
        limit: Int = 60
    ) -> [Date] {
        let cal = clock.calendar
        let todayStart = clock.dayStart(containing: now)
        var dates: [Date] = []
        for dayOffset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else { continue }
            for m in minutes.sorted() {
                guard let fire = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) else { continue }
                if fire <= now { continue }
                if let pausedUntil, fire < pausedUntil { continue }
                if goalMetToday && clock.dayStart(containing: fire) == todayStart { continue }
                dates.append(fire)
                if dates.count >= limit { return dates }
            }
        }
        return dates
    }

    /// Supportive, no-pressure copy. Never mentions shortfalls or pushes past the goal.
    static let messages: [(title: String, body: String)] = [
        ("Sip break?", "If you're thirsty, now's a nice moment for a drink."),
        ("A gentle nudge", "Had something to drink lately? Tap to log it — or ignore this, no worries."),
        ("Glass check", "A few sips might feel good. Listen to your body."),
        ("Hello from Siprup", "Just a friendly reminder to log any drinks you've had."),
    ]
}

@MainActor
enum ReminderScheduler {
    static let categoryID = "SIPRUP_REMINDER"
    static let pauseTodayAction = "PAUSE_TODAY"
    private static let idPrefix = "siprup.reminder."

    static var center: UNUserNotificationCenter { .current() }

    static func registerCategories() {
        let pause = UNNotificationAction(identifier: pauseTodayAction, title: "Pause for today", options: [])
        let category = UNNotificationCategory(identifier: categoryID, actions: [pause], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    static func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Rebuilds pending reminders from current settings and today's log.
    static func refresh(context: ModelContext) async {
        let d = UserDefaults.standard
        center.removeAllPendingNotificationRequests()
        guard d.bool(forKey: Prefs.remindersOn), await isAuthorized() else { return }

        let interval = d.object(forKey: Prefs.reminderInterval) as? Int ?? Prefs.defaultInterval
        let quietStart = d.object(forKey: Prefs.quietStart) as? Int ?? Prefs.defaultQuietStart
        let quietEnd = d.object(forKey: Prefs.quietEnd) as? Int ?? Prefs.defaultQuietEnd
        let goal = d.object(forKey: Prefs.goalML) as? Double ?? Prefs.defaultGoalML
        let resetHour = d.object(forKey: Prefs.resetHour) as? Int ?? Prefs.defaultResetHour
        let pausedRaw = d.double(forKey: Prefs.pausedUntil)
        let pausedUntil = pausedRaw > 0 ? Date(timeIntervalSince1970: pausedRaw) : nil

        let clock = DayClock(resetHour: resetHour)
        let now = Date()
        let start = clock.dayStart(containing: now)
        let end = clock.dayEnd(forStart: start)
        let descriptor = FetchDescriptor<DrinkEntry>(predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end })
        let todayTotal = ((try? context.fetch(descriptor)) ?? []).reduce(0) { $0 + $1.volumeML }

        let dates = ReminderPlan.fireDates(
            now: now,
            minutes: ReminderPlan.minutesOfDay(intervalMinutes: interval, quietStart: quietStart, quietEnd: quietEnd),
            pausedUntil: pausedUntil,
            goalMetToday: todayTotal >= goal,
            clock: clock
        )

        for (i, date) in dates.enumerated() {
            let msg = ReminderPlan.messages[i % ReminderPlan.messages.count]
            let content = UNMutableNotificationContent()
            content.title = msg.title
            content.body = msg.body
            content.categoryIdentifier = categoryID
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: idPrefix + "\(Int(date.timeIntervalSince1970))", content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// Pauses until the next day starts. Removes pending reminders that fall inside the pause.
    static func pauseForToday() async {
        let d = UserDefaults.standard
        let resetHour = d.object(forKey: Prefs.resetHour) as? Int ?? Prefs.defaultResetHour
        let clock = DayClock(resetHour: resetHour)
        let until = clock.dayEnd(forStart: clock.dayStart(containing: Date()))
        d.set(until.timeIntervalSince1970, forKey: Prefs.pausedUntil)

        let pending = await center.pendingNotificationRequests()
        let ids = pending.compactMap { req -> String? in
            guard let next = (req.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { return nil }
            return next < until ? req.identifier : nil
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
