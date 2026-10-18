import Charts
import SwiftData
import SwiftUI

struct DaySummary: Identifiable, Hashable {
    let start: Date
    let end: Date
    let total: Double
    let goal: Double
    let count: Int
    var id: Date { start }
    var met: Bool { total >= goal }
}

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DrinkEntry.timestamp, order: .reverse) private var entries: [DrinkEntry]
    @Query(sort: \GoalRecord.dayStart) private var goalRecords: [GoalRecord]
    @AppStorage(Prefs.resetHour) private var resetHour = Prefs.defaultResetHour
    @AppStorage(Prefs.goalML) private var goalML = Prefs.defaultGoalML
    @AppStorage(Prefs.unit) private var unitRaw = UnitSystem.metric.rawValue

    private var unit: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var clock: DayClock { DayClock(resetHour: resetHour) }

    /// Every day from today back to the first logged day (max one year), including empty days.
    private var days: [DaySummary] {
        let clock = self.clock
        var totals: [Date: (Double, Int)] = [:]
        for e in entries {
            let start = clock.dayStart(containing: e.timestamp)
            let current = totals[start] ?? (0, 0)
            totals[start] = (current.0 + e.volumeML, current.1 + 1)
        }
        let today = clock.dayStart(containing: Date())
        let earliest = entries.last.map { clock.dayStart(containing: $0.timestamp) } ?? today
        var result: [DaySummary] = []
        var day = today
        while day >= earliest && result.count < 366 {
            let t = totals[day] ?? (0, 0)
            result.append(DaySummary(start: day, end: clock.dayEnd(forStart: day), total: t.0,
                                     goal: GoalBook.goal(for: day, records: goalRecords, current: goalML), count: t.1))
            guard let prev = clock.calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return result
    }

    var body: some View {
        NavigationStack {
            let days = self.days
            List {
                Section("Last 7 days") {
                    WeekChart(days: Array(days.prefix(7)).reversed(), unit: unit)
                        .frame(height: 180)
                        .padding(.vertical, 8)
                }
                Section("Days") {
                    ForEach(days) { day in
                        NavigationLink(value: day) {
                            HistoryRow(day: day, title: clock.title(for: day.start), unit: unit)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: DaySummary.self) { day in
                DayLogView(dayStart: day.start, dayEnd: day.end, goalML: day.goal)
                    .navigationTitle(clock.title(for: day.start))
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct HistoryRow: View {
    let day: DaySummary
    let title: String
    let unit: UnitSystem

    var body: some View {
        let progress = min(day.total / max(day.goal, 1), 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.body.weight(.semibold))
                Spacer()
                if day.met {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Goal met")
                }
                Text(Volume.format(day.total, unit)).monospacedDigit()
                    .foregroundStyle(day.count == 0 ? .secondary : .primary)
            }
            ProgressView(value: progress).tint(day.met ? .green : .accentColor)
            Text(day.count == 0
                 ? "Nothing logged · goal \(Volume.format(day.goal, unit))"
                 : "\(Int((progress * 100).rounded()))% of \(Volume.format(day.goal, unit)) · \(day.count) \(day.count == 1 ? "drink" : "drinks")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct WeekChart: View {
    let days: [DaySummary]
    let unit: UnitSystem

    var body: some View {
        Chart {
            ForEach(days) { day in
                BarMark(
                    x: .value("Day", day.start, unit: .day),
                    y: .value("Logged", Volume.toDisplay(day.total, unit))
                )
                .foregroundStyle(day.met ? Color.green.gradient : Color.accentColor.gradient)
                .cornerRadius(6)
                .accessibilityLabel(day.start.formatted(.dateTime.weekday(.wide)))
                .accessibilityValue("\(Volume.format(day.total, unit)) of \(Volume.format(day.goal, unit))")

                // Each day's own goal, as a short tick.
                RuleMark(
                    xStart: .value("Day", day.start, unit: .day),
                    xEnd: .value("Day", day.start.addingTimeInterval(20 * 3600), unit: .hour),
                    y: .value("Goal", Volume.toDisplay(day.goal, unit))
                )
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .chartYAxisLabel(unit.shortLabel)
    }
}
