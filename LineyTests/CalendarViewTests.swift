import SwiftData
import Testing
import UIKit
@testable import Liney

/// The month calendar the timeline repository answers, with a fixed calendar and current date.
@Suite
struct MonthCalendarQueryTests {
    let calendar: Calendar

    init() {
        // All-day Entries are stored at the start of their day in the current time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_US")
        self.calendar = calendar
    }

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    func query(_ entries: [JournalEntry], now: Date, firstWeekday: Int = 1) async throws -> MonthCalendar {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        entries.forEach { context.insert($0) }
        try context.save()
        let repository = TimelineRepository(container: container)
        try await repository.reload()
        var calendar = calendar
        calendar.firstWeekday = firstWeekday
        return try await repository.monthCalendar(calendar: calendar, now: now)
    }

    @Test func monthsRunFromEarliestEntryAcrossYearBoundaryToCurrentMonth() async throws {
        let result = try await query([
            JournalEntry(title: "Later", entryDate: try date(2026, 1, 5)),
            JournalEntry(title: "Earliest", entryDate: try date(2025, 11, 20))
        ], now: try date(2026, 2, 10))
        #expect(result.months.map(\.start) == [
            try date(2025, 11, 1, hour: 0), try date(2025, 12, 1, hour: 0),
            try date(2026, 1, 1, hour: 0), try date(2026, 2, 1, hour: 0)
        ])
        #expect(result.months.map(\.days.count) == [30, 31, 31, 28])
    }

    @Test func emptyJournalShowsOnlyCurrentMonth() async throws {
        let result = try await query([], now: try date(2026, 10, 12))
        #expect(result.months.map(\.start) == [try date(2026, 10, 1, hour: 0)])
        #expect(result.months[0].days.map(\.number) == Array(1...31))
    }

    @Test func dayStatesListEntriesInTimelineOrder() async throws {
        let morning = JournalEntry(title: "Morning", entryDate: try date(2026, 7, 3, hour: 8))
        let evening = JournalEntry(title: "Evening", entryDate: try date(2026, 7, 3, hour: 20))
        let allDay = JournalEntry(title: "All Day", entryDate: try date(2026, 7, 3), isAllDay: true)
        let today = JournalEntry(title: "Today", entryDate: try date(2026, 7, 15, hour: 9))
        let result = try await query([allDay, morning, today, evening], now: try date(2026, 7, 15, hour: 13))
        let days = try #require(result.months.last).days

        #expect(days[2].state == .hasEntries)
        #expect(days[2].entryIDs == [evening.id, morning.id, allDay.id])
        #expect(days[2].entryCount == 3)
        #expect(!days[2].isToday)
        #expect(days[3].state == .noEntries)
        #expect(days[3].entryIDs.isEmpty)
        #expect(days[14].isToday)
        #expect(days[14].state == .hasEntries)
        #expect(days[15].state == .future)
        #expect(days[30].state == .future)
        #expect(days.filter(\.isToday).count == 1)
        #expect(days.prefix(14).allSatisfy { $0.state != .future })
    }

    @Test func emptyTodayIsNotFuture() async throws {
        let result = try await query([], now: try date(2026, 7, 15, hour: 23))
        let today = try #require(result.months.last?.days[14])
        #expect(today.isToday)
        #expect(today.state == .noEntries)
    }

    @Test(arguments: [(1, 3), (2, 2)])
    func weeksStartOnTheCalendarsFirstWeekday(firstWeekday: Int, leadingEmptyDays: Int) async throws {
        // July 1, 2026 is a Wednesday.
        let result = try await query([], now: try date(2026, 7, 15), firstWeekday: firstWeekday)
        #expect(result.months[0].leadingEmptyDays == leadingEmptyDays)
    }
}
