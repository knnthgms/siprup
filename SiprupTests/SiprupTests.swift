import XCTest
@testable import Siprup

final class DayClockTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    func testDrinkAfterMidnightCountsTowardPreviousDay() {
        let clock = DayClock(resetHour: 4, calendar: cal)
        XCTAssertEqual(clock.dayStart(containing: date(18, 1)), date(17, 4))
        XCTAssertEqual(clock.dayStart(containing: date(18, 4)), date(18, 4))
        XCTAssertEqual(clock.dayStart(containing: date(18, 23)), date(18, 4))
    }

    func testMidnightReset() {
        let clock = DayClock(resetHour: 0, calendar: cal)
        XCTAssertEqual(clock.dayStart(containing: date(18, 0, 30)), date(18, 0))
    }
}

final class VolumeTests: XCTestCase {
    func testRoundTrip() {
        XCTAssertEqual(Volume.toML(8, .us), 236.588, accuracy: 0.01)
        XCTAssertEqual(Volume.toDisplay(Volume.toML(12, .us), .us), 12, accuracy: 0.0001)
        XCTAssertEqual(Volume.toML(250, .metric), 250)
    }

    func testParseAcceptsCommaDecimal() {
        XCTAssertEqual(Volume.parse("12,5"), 12.5)
        XCTAssertNil(Volume.parse("abc"))
    }

    func testRoundedGoal() {
        XCTAssertEqual(Volume.roundedGoal(2010, .metric), 2000)
        XCTAssertEqual(Volume.toDisplay(Volume.roundedGoal(2000, .us), .us), 68, accuracy: 0.0001)
    }
}

final class NutritionTests: XCTestCase {
    func testSumKeepsUnknownsUnknown() {
        let a = NutritionEstimate(caffeineMg: 95, sugarG: nil, kcal: 2)
        let b = NutritionEstimate(caffeineMg: nil, sugarG: nil, kcal: 45)
        let sum = a + b
        XCTAssertEqual(sum.caffeineMg, 95)
        XCTAssertNil(sum.sugarG)
        XCTAssertEqual(sum.kcal, 47)
    }
}

final class ReminderPlanTests: XCTestCase {
    func testTimesStayOutsideQuietHours() {
        let mins = ReminderPlan.minutesOfDay(intervalMinutes: 120, quietStart: 22 * 60, quietEnd: 8 * 60)
        XCTAssertEqual(mins, [10, 12, 14, 16, 18, 20].map { $0 * 60 })
    }

    func testQuietHoursWithinDay() {
        // Quiet 13:00–14:00 only: awake window wraps past midnight.
        let mins = ReminderPlan.minutesOfDay(intervalMinutes: 360, quietStart: 13 * 60, quietEnd: 14 * 60)
        XCTAssertEqual(mins, [20 * 60, 2 * 60, 8 * 60])
    }

    func testGoalMetSkipsRestOfToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let clock = DayClock(resetHour: 4, calendar: cal)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 11))!
        let minutes = [10 * 60, 14 * 60, 18 * 60]

        let notMet = ReminderPlan.fireDates(now: now, minutes: minutes, days: 2, pausedUntil: nil, goalMetToday: false, clock: clock)
        XCTAssertEqual(notMet.count, 5) // 14, 18 today + 3 tomorrow

        let met = ReminderPlan.fireDates(now: now, minutes: minutes, days: 2, pausedUntil: nil, goalMetToday: true, clock: clock)
        XCTAssertEqual(met.count, 3)
        XCTAssertTrue(met.allSatisfy { clock.dayStart(containing: $0) > clock.dayStart(containing: now) })
    }

    func testPauseSkipsReminders() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let clock = DayClock(resetHour: 4, calendar: cal)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9))!
        let paused = now.addingTimeInterval(6 * 3600) // until 15:00
        let dates = ReminderPlan.fireDates(now: now, minutes: [10 * 60, 14 * 60, 16 * 60], days: 1,
                                           pausedUntil: paused, goalMetToday: false, clock: clock)
        XCTAssertEqual(dates.count, 1)
    }
}

final class ContrastTests: XCTestCase {
    func testPicksReadableTextColour() {
        XCTAssertTrue(Contrast.prefersDarkText(onHex: "F1EBDD"))   // milk
        XCTAssertTrue(Contrast.prefersDarkText(onHex: "5AB8F0"))   // water
        XCTAssertFalse(Contrast.prefersDarkText(onHex: "6B4428"))  // coffee
        XCTAssertFalse(Contrast.prefersDarkText(onHex: "16212B"))  // dark empty glass
    }
}
