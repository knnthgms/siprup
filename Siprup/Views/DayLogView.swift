import SwiftData
import SwiftUI

/// Chronological list of one day's drinks with totals; tap to edit, swipe to delete.
struct DayLogView: View {
    let dayStart: Date
    let dayEnd: Date
    let goalML: Double

    @Query private var entries: [DrinkEntry]
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.unit) private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage(Prefs.showNutrition) private var showNutrition = true
    @State private var editing: DrinkEntry?
    @State private var adding = false

    init(dayStart: Date, dayEnd: Date, goalML: Double) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.goalML = goalML
        let s = dayStart, e = dayEnd
        _entries = Query(filter: #Predicate<DrinkEntry> { $0.timestamp >= s && $0.timestamp < e },
                         sort: \DrinkEntry.timestamp)
    }

    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var total: Double { entries.reduce(0) { $0 + $1.volumeML } }
    private var isCurrentDay: Bool { Date() >= dayStart && Date() < dayEnd }

    var body: some View {
        List {
            Section {
                DayProgressRow(total: total, goal: goalML, unit: unit, drinkCount: entries.count)
            }

            Section("Drinks") {
                if entries.isEmpty {
                    Text("No drinks logged.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    Button { editing = entry } label: { EntryRow(entry: entry, unit: unit) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Edit or delete")
                }
                .onDelete { offsets in
                    offsets.map { entries[$0] }.forEach(context.delete)
                    try? context.save()
                    Task { await ReminderScheduler.refresh(context: context) }
                }
            }

            if showNutrition {
                let est = entries.reduce(NutritionEstimate()) { $0 + $1.estimate }
                if !est.isEmpty {
                    Section {
                        NutritionRows(estimate: est)
                    } header: {
                        Text("Estimated totals (approximate)")
                    } footer: {
                        Text("Based on typical values for drinks with data. Custom drinks without estimates aren't included.")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add drink", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { entry in DrinkEditorView(mode: .edit(entry)) }
        .sheet(isPresented: $adding) {
            DrinkEditorView(mode: .add(defaultDate: isCurrentDay ? Date() : dayStart.addingTimeInterval(8 * 3600)))
        }
    }
}

struct EntryRow: View {
    let entry: DrinkEntry
    let unit: UnitSystem

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: entry.displayColorHex))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.primary.opacity(0.2), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.body.weight(.medium))
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Volume.format(entry.volumeML, unit))
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DayProgressRow: View {
    let total: Double
    let goal: Double
    let unit: UnitSystem
    let drinkCount: Int

    var body: some View {
        let progress = min(total / max(goal, 1), 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Volume.format(total, unit)).font(.title.bold())
                Text("of \(Volume.format(goal, unit))").foregroundStyle(.secondary)
                Spacer()
                if total >= goal {
                    Label("Goal met", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            ProgressView(value: progress).tint(total >= goal ? .green : .accentColor)
            Text("\(drinkCount) \(drinkCount == 1 ? "drink" : "drinks") · \(Int((progress * 100).rounded()))% of goal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
