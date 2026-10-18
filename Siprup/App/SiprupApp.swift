import SwiftData
import SwiftUI
import UserNotifications

@main
struct SiprupApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    init() {
        let args = ProcessInfo.processInfo.arguments
        let inMemory = args.contains("-SiprupInMemory")
        do {
            container = try ModelContainer(
                for: DrinkType.self, DrinkEntry.self, GoalRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
            )
        } catch {
            fatalError("Could not open Siprup's local store: \(error)")
        }
        UserDefaults.standard.register(defaults: [
            Prefs.unit: UnitSystem.localeDefault.rawValue,
            Prefs.goalML: UnitSystem.localeDefault == .us ? 64 * Volume.mlPerFlOz : Prefs.defaultGoalML,
            Prefs.resetHour: Prefs.defaultResetHour,
            Prefs.showNutrition: true,
            Prefs.reminderInterval: Prefs.defaultInterval,
            Prefs.quietStart: Prefs.defaultQuietStart,
            Prefs.quietEnd: Prefs.defaultQuietEnd,
        ])
        MainActor.assumeIsolated {
            Seeder.seedIfNeeded(container.mainContext)
            if args.contains("-SiprupDemoData") {
                Seeder.seedDemo(container.mainContext)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { ReminderScheduler.registerCategories() }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == ReminderScheduler.pauseTodayAction {
            await ReminderScheduler.pauseForToday()
        }
    }
}

@MainActor
enum Seeder {
    static func seedIfNeeded(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<DrinkType>())) ?? 0
        if count == 0 {
            BuiltInDrinks.make().forEach { context.insert($0) }
        }
        let goals = (try? context.fetchCount(FetchDescriptor<GoalRecord>())) ?? 0
        if goals == 0 {
            let d = UserDefaults.standard
            let clock = DayClock(resetHour: d.integer(forKey: Prefs.resetHour))
            context.insert(GoalRecord(dayStart: clock.dayStart(containing: Date()), goalML: d.double(forKey: Prefs.goalML)))
        }
        try? context.save()
    }

    /// Sample data for screenshots and simulator testing (launch with -SiprupDemoData).
    static func seedDemo(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<DrinkEntry>())) ?? 0
        guard existing == 0 else { return }
        let types = (try? context.fetch(FetchDescriptor<DrinkType>())) ?? []
        func type(_ key: String) -> DrinkType? { types.first { $0.key == key } }
        let d = UserDefaults.standard
        let clock = DayClock(resetHour: d.integer(forKey: Prefs.resetHour))
        let now = Date()
        let start = clock.dayStart(containing: now)

        let today: [(String, Double, Double)] = [
            ("coffee", 200, -9), ("water", 250, -7.5), ("tea", 300, -5.5), ("juice", 250, -4),
            ("water", 250, -3), ("coffee", 200, -1.5), ("water", 250, -0.3),
        ]
        for (key, ml, hours) in today {
            guard let t = type(key) else { continue }
            let time = max(now.addingTimeInterval(hours * 3600), start.addingTimeInterval(60))
            context.insert(DrinkEntry(timestamp: time, volumeML: ml, type: t))
        }

        let pattern: [[(String, Double)]] = [
            [("water", 750), ("coffee", 250), ("tea", 300), ("water", 500)],
            [("water", 1000), ("sparkling", 330), ("coffee", 200), ("water", 500)],
            [("coffee", 250), ("water", 500), ("milk", 200)],
            [("water", 500), ("tea", 250), ("tea", 250), ("water", 750), ("juice", 200)],
            [("water", 1500), ("coffee", 250), ("beer", 568)],
            [("water", 400), ("cola", 330)],
            [("water", 750), ("coffee", 250), ("water", 750), ("tea", 300)],
        ]
        for (i, drinks) in pattern.enumerated() {
            guard let dayStart = Calendar.current.date(byAdding: .day, value: -(i + 1), to: start) else { continue }
            for (j, (key, ml)) in drinks.enumerated() {
                guard let t = type(key) else { continue }
                let time = dayStart.addingTimeInterval(Double(4 + j * 3) * 3600)
                context.insert(DrinkEntry(timestamp: time, volumeML: ml, type: t))
            }
        }
        try? context.save()
    }
}
