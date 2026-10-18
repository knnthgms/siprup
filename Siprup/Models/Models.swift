import Foundation
import SwiftData

/// A kind of drink the user can log. Built-in types are seeded on first launch;
/// users can add their own and adjust the (estimated) nutrition of any type.
@Model
final class DrinkType {
    @Attribute(.unique) var id: UUID
    /// Stable key for built-in types ("water", "coffee", …); nil for custom types.
    var key: String?
    var name: String
    var colorHex: String
    var isFizzy: Bool
    var isBuiltIn: Bool
    var isHidden: Bool
    var sortOrder: Int
    // Rough estimates per 100 ml. nil means "unknown".
    var caffeineMgPer100ml: Double?
    var sugarGPer100ml: Double?
    var kcalPer100ml: Double?

    @Relationship(deleteRule: .nullify, inverse: \DrinkEntry.type)
    var entries: [DrinkEntry]? = []

    init(
        key: String? = nil,
        name: String,
        colorHex: String,
        isFizzy: Bool = false,
        isBuiltIn: Bool = false,
        sortOrder: Int = 100,
        caffeineMgPer100ml: Double? = nil,
        sugarGPer100ml: Double? = nil,
        kcalPer100ml: Double? = nil
    ) {
        self.id = UUID()
        self.key = key
        self.name = name
        self.colorHex = colorHex
        self.isFizzy = isFizzy
        self.isBuiltIn = isBuiltIn
        self.isHidden = false
        self.sortOrder = sortOrder
        self.caffeineMgPer100ml = caffeineMgPer100ml
        self.sugarGPer100ml = sugarGPer100ml
        self.kcalPer100ml = kcalPer100ml
    }

    var hasFoam: Bool { key == "beer" }
    var hasNutritionData: Bool {
        caffeineMgPer100ml != nil || sugarGPer100ml != nil || kcalPer100ml != nil
    }
}

/// One logged drink. Name and colour are snapshotted so history survives
/// if a custom drink type is later deleted.
@Model
final class DrinkEntry {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var volumeML: Double
    var type: DrinkType?
    var typeNameSnapshot: String
    var colorHexSnapshot: String

    init(timestamp: Date, volumeML: Double, type: DrinkType) {
        self.id = UUID()
        self.timestamp = timestamp
        self.volumeML = volumeML
        self.type = type
        self.typeNameSnapshot = type.name
        self.colorHexSnapshot = type.colorHex
    }

    func setType(_ newType: DrinkType) {
        type = newType
        typeNameSnapshot = newType.name
        colorHexSnapshot = newType.colorHex
    }

    var displayName: String { type?.name ?? typeNameSnapshot }
    var displayColorHex: String { type?.colorHex ?? colorHexSnapshot }
    var layerKey: String { type.map { $0.id.uuidString } ?? "snapshot-\(typeNameSnapshot)" }
    var estimate: NutritionEstimate { NutritionEstimate(type: type, volumeML: volumeML) }
}

/// The goal in effect from `dayStart` onward, so past days keep the goal they had.
@Model
final class GoalRecord {
    var dayStart: Date
    var goalML: Double

    init(dayStart: Date, goalML: Double) {
        self.dayStart = dayStart
        self.goalML = goalML
    }
}

enum GoalBook {
    static func goal(for dayStart: Date, records: [GoalRecord], current: Double) -> Double {
        records
            .filter { $0.dayStart <= dayStart }
            .max(by: { $0.dayStart < $1.dayStart })?
            .goalML ?? current
    }

    /// Records the current goal as the goal for today (and onward).
    @MainActor
    static func recordGoal(_ goalML: Double, dayStart: Date, context: ModelContext) {
        let start = dayStart
        let descriptor = FetchDescriptor<GoalRecord>(predicate: #Predicate { $0.dayStart == start })
        if let existing = try? context.fetch(descriptor).first {
            existing.goalML = goalML
        } else {
            context.insert(GoalRecord(dayStart: dayStart, goalML: goalML))
        }
        try? context.save()
    }
}

/// Approximate nutrition for a logged amount. Always presented as an estimate.
struct NutritionEstimate: Equatable {
    var caffeineMg: Double?
    var sugarG: Double?
    var kcal: Double?

    init(caffeineMg: Double? = nil, sugarG: Double? = nil, kcal: Double? = nil) {
        self.caffeineMg = caffeineMg
        self.sugarG = sugarG
        self.kcal = kcal
    }

    init(type: DrinkType?, volumeML: Double) {
        let f = volumeML / 100
        caffeineMg = type?.caffeineMgPer100ml.map { $0 * f }
        sugarG = type?.sugarGPer100ml.map { $0 * f }
        kcal = type?.kcalPer100ml.map { $0 * f }
    }

    var isEmpty: Bool { caffeineMg == nil && sugarG == nil && kcal == nil }

    static func + (a: NutritionEstimate, b: NutritionEstimate) -> NutritionEstimate {
        func add(_ x: Double?, _ y: Double?) -> Double? {
            switch (x, y) {
            case (nil, nil): return nil
            default: return (x ?? 0) + (y ?? 0)
            }
        }
        return NutritionEstimate(caffeineMg: add(a.caffeineMg, b.caffeineMg),
                                 sugarG: add(a.sugarG, b.sugarG),
                                 kcal: add(a.kcal, b.kcal))
    }
}

enum BuiltInDrinks {
    /// Typical values per 100 ml, rounded. These are rough estimates — real drinks vary a lot.
    static func make() -> [DrinkType] {
        [
            DrinkType(key: "water", name: "Water", colorHex: "5AB8F0", isBuiltIn: true, sortOrder: 0,
                      caffeineMgPer100ml: 0, sugarGPer100ml: 0, kcalPer100ml: 0),
            DrinkType(key: "sparkling", name: "Sparkling water", colorHex: "A6DCF5", isFizzy: true, isBuiltIn: true, sortOrder: 1,
                      caffeineMgPer100ml: 0, sugarGPer100ml: 0, kcalPer100ml: 0),
            DrinkType(key: "coffee", name: "Coffee", colorHex: "6B4428", isBuiltIn: true, sortOrder: 2,
                      caffeineMgPer100ml: 40, sugarGPer100ml: 0, kcalPer100ml: 1),
            DrinkType(key: "tea", name: "Tea", colorHex: "B87A2E", isBuiltIn: true, sortOrder: 3,
                      caffeineMgPer100ml: 20, sugarGPer100ml: 0, kcalPer100ml: 1),
            DrinkType(key: "juice", name: "Orange juice", colorHex: "F7A21B", isBuiltIn: true, sortOrder: 4,
                      caffeineMgPer100ml: 0, sugarGPer100ml: 8.4, kcalPer100ml: 45),
            DrinkType(key: "milk", name: "Milk", colorHex: "F1EBDD", isBuiltIn: true, sortOrder: 5,
                      caffeineMgPer100ml: 0, sugarGPer100ml: 5, kcalPer100ml: 50),
            DrinkType(key: "cola", name: "Cola", colorHex: "4F2316", isFizzy: true, isBuiltIn: true, sortOrder: 6,
                      caffeineMgPer100ml: 10, sugarGPer100ml: 10.6, kcalPer100ml: 42),
            DrinkType(key: "beer", name: "Beer", colorHex: "E8B033", isFizzy: true, isBuiltIn: true, sortOrder: 7,
                      caffeineMgPer100ml: 0, sugarGPer100ml: 0, kcalPer100ml: 43),
        ]
    }
}
