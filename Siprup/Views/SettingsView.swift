import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @AppStorage(Prefs.goalML) private var goalML = Prefs.defaultGoalML
    @AppStorage(Prefs.unit) private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage(Prefs.resetHour) private var resetHour = Prefs.defaultResetHour
    @AppStorage(Prefs.reduceMotion) private var reduceMotion = false
    @AppStorage(Prefs.showNutrition) private var showNutrition = true
    @AppStorage(Prefs.remindersOn) private var remindersOn = false
    @AppStorage(Prefs.reminderInterval) private var interval = Prefs.defaultInterval
    @AppStorage(Prefs.quietStart) private var quietStart = Prefs.defaultQuietStart
    @AppStorage(Prefs.quietEnd) private var quietEnd = Prefs.defaultQuietEnd
    @AppStorage(Prefs.pausedUntil) private var pausedUntil: Double = 0

    @State private var notificationsDenied = false

    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var clock: DayClock { DayClock(resetHour: resetHour) }
    private var isPaused: Bool { pausedUntil > Date().timeIntervalSince1970 }

    var body: some View {
        NavigationStack {
            Form {
                goalSection
                remindersSection
                displaySection
                Section {
                    NavigationLink("Drink types") { DrinkTypesListView() }
                }
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: goalML) { _, new in
                GoalBook.recordGoal(new, dayStart: clock.dayStart(containing: Date()), context: context)
                refreshReminders()
            }
            .onChange(of: unitRaw) { _, _ in goalML = Volume.roundedGoal(goalML, unit) }
            .onChange(of: interval) { _, _ in refreshReminders() }
            .onChange(of: quietStart) { _, _ in refreshReminders() }
            .onChange(of: quietEnd) { _, _ in refreshReminders() }
            .onChange(of: pausedUntil) { _, _ in refreshReminders() }
            .onChange(of: resetHour) { _, _ in refreshReminders() }
        }
    }

    // MARK: Sections

    private var goalSection: some View {
        Section {
            Stepper(value: $goalML, in: Prefs.goalRangeML, step: Volume.goalStep(unit)) {
                LabeledContent("Daily goal", value: Volume.format(goalML, unit))
            }
            .accessibilityValue(Volume.format(goalML, unit))
            Picker("Units", selection: $unitRaw) {
                ForEach(UnitSystem.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("New day starts at", selection: $resetHour) {
                ForEach(0..<7) { hour in
                    Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
                        .formatted(date: .omitted, time: .shortened))
                        .tag(hour)
                }
            }
        } header: {
            Text("Goal")
        } footer: {
            Text("Drinks logged before this time count toward the previous day. Fluid needs vary with body, activity, climate and health — if a clinician has given you a target or limit, use theirs.")
        }
    }

    private var remindersSection: some View {
        Section {
            Toggle("Gentle reminders", isOn: Binding(get: { remindersOn }, set: setReminders))
            if notificationsDenied {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifications are turned off for Siprup in iOS Settings.")
                        .font(.footnote)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            if remindersOn {
                Picker("Every", selection: $interval) {
                    Text("1 hour").tag(60)
                    Text("1½ hours").tag(90)
                    Text("2 hours").tag(120)
                    Text("3 hours").tag(180)
                    Text("4 hours").tag(240)
                }
                DatePicker("Quiet from", selection: minutesBinding($quietStart), displayedComponents: .hourAndMinute)
                DatePicker("Quiet until", selection: minutesBinding($quietEnd), displayedComponents: .hourAndMinute)
                if isPaused {
                    LabeledContent("Paused until",
                                   value: Date(timeIntervalSince1970: pausedUntil).formatted(date: .abbreviated, time: .shortened))
                    Button("Resume reminders") { pausedUntil = 0 }
                } else {
                    Menu {
                        Button("For 1 hour") { pause(hours: 1) }
                        Button("For 3 hours") { pause(hours: 3) }
                        Button("For the rest of today") {
                            pausedUntil = clock.dayEnd(forStart: clock.dayStart(containing: Date())).timeIntervalSince1970
                        }
                    } label: {
                        Label("Pause reminders", systemImage: "pause.circle")
                    }
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Friendly nudges, never during quiet hours. They stop for the day once you reach your goal. You can also pause from any reminder notification.")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("Reduce motion", isOn: $reduceMotion)
            Toggle("Show nutrition estimates", isOn: $showNutrition)
        } header: {
            Text("Display")
        } footer: {
            Text("Reduce motion keeps the liquid still — no waves, sloshing or rising bubbles. It also turns on automatically when Reduce Motion is enabled in iOS Accessibility settings.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Text("Siprup is a simple drink log, not a medical device. The glass illustrates what you've logged — it doesn't measure hydration, and the layers don't show how drinks mix in your body. All beverages, including coffee, count toward your logged fluid. History is stored only on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func setReminders(_ on: Bool) {
        guard on else {
            remindersOn = false
            refreshReminders()
            return
        }
        Task {
            let granted = await ReminderScheduler.requestAuthorization()
            notificationsDenied = !granted
            remindersOn = granted
            refreshReminders()
        }
    }

    private func pause(hours: Double) {
        pausedUntil = Date().addingTimeInterval(hours * 3600).timeIntervalSince1970
    }

    private func refreshReminders() {
        Task { await ReminderScheduler.refresh(context: context) }
    }

    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}
