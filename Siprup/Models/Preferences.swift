import Foundation

/// UserDefaults keys. Settings live in UserDefaults; drink history lives in SwiftData.
enum Prefs {
    static let goalML = "goalML"
    static let unit = "unitSystem"
    static let resetHour = "dayResetHour"
    static let reduceMotion = "reduceMotion"
    static let showNutrition = "showNutrition"
    static let remindersOn = "remindersOn"
    static let reminderInterval = "reminderIntervalMinutes"
    static let quietStart = "quietStartMinutes"
    static let quietEnd = "quietEndMinutes"
    static let pausedUntil = "remindersPausedUntil"

    static let defaultGoalML = 2000.0
    static let defaultResetHour = 4
    static let defaultInterval = 120
    static let defaultQuietStart = 22 * 60
    static let defaultQuietEnd = 8 * 60
    static let goalRangeML: ClosedRange<Double> = 500...6000
}

enum UnitSystem: String, CaseIterable, Identifiable {
    case metric, us

    var id: String { rawValue }
    var label: String { self == .metric ? "Metric (ml, L)" : "US customary (fl oz)" }
    var shortLabel: String { self == .metric ? "ml" : "fl oz" }

    static var localeDefault: UnitSystem {
        Locale.current.measurementSystem == .us ? .us : .metric
    }
}

enum Volume {
    static let mlPerFlOz = 29.5735295625

    static func toDisplay(_ ml: Double, _ unit: UnitSystem) -> Double {
        unit == .metric ? ml : ml / mlPerFlOz
    }

    static func toML(_ value: Double, _ unit: UnitSystem) -> Double {
        unit == .metric ? value : value * mlPerFlOz
    }

    /// "750 ml", "1.25 L", "25.4 fl oz"
    static func format(_ ml: Double, _ unit: UnitSystem) -> String {
        switch unit {
        case .metric:
            if ml >= 1000 {
                return "\(number(ml / 1000, maxFraction: 2)) L"
            }
            return "\(number(ml.rounded(), maxFraction: 0)) ml"
        case .us:
            let oz = ml / mlPerFlOz
            return "\(number(oz, maxFraction: oz < 10 ? 1 : 0)) fl oz"
        }
    }

    /// Plain number in the display unit for editing (no grouping separators).
    static func editableString(_ ml: Double, _ unit: UnitSystem) -> String {
        let v = toDisplay(ml, unit)
        let f = NumberFormatter()
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = unit == .metric ? 0 : 1
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    static func number(_ v: Double, maxFraction: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = maxFraction
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    struct Preset: Identifiable, Hashable {
        let name: String
        let ml: Double
        var id: Double { ml }
    }

    static func presets(_ unit: UnitSystem) -> [Preset] {
        switch unit {
        case .metric:
            return [
                Preset(name: "Espresso", ml: 40),
                Preset(name: "Small glass", ml: 150),
                Preset(name: "Cup", ml: 250),
                Preset(name: "Can", ml: 330),
                Preset(name: "Bottle", ml: 500),
                Preset(name: "Pint", ml: 568),
            ]
        case .us:
            return [4, 8, 12, 16, 20, 24].map { oz in
                let name: String
                switch oz {
                case 4: name = "Small"
                case 8: name = "Cup"
                case 12: name = "Can"
                case 16: name = "Pint"
                case 20: name = "Bottle"
                default: name = "Large"
                }
                return Preset(name: name, ml: Double(oz) * mlPerFlOz)
            }
        }
    }

    /// Nice rounding when switching units so the goal reads cleanly.
    static func roundedGoal(_ ml: Double, _ unit: UnitSystem) -> Double {
        switch unit {
        case .metric: return (ml / 50).rounded() * 50
        case .us: return (ml / mlPerFlOz).rounded() * mlPerFlOz
        }
    }

    static func goalStep(_ unit: UnitSystem) -> Double {
        unit == .metric ? 50 : 2 * mlPerFlOz
    }
}

/// A "day" starts at the user's reset hour, so a 1 a.m. tea counts toward the previous evening.
struct DayClock {
    var resetHour: Int
    var calendar: Calendar = .current

    func dayStart(containing date: Date) -> Date {
        let reset = calendar.date(bySettingHour: resetHour, minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
        if date >= reset { return reset }
        return calendar.date(byAdding: .day, value: -1, to: reset) ?? reset
    }

    func dayEnd(forStart start: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    func title(for dayStart: Date, now: Date = Date()) -> String {
        let today = self.dayStart(containing: now)
        if dayStart == today { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), dayStart == y { return "Yesterday" }
        return dayStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
