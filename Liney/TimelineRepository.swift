import Foundation
import SwiftData

struct TimelineEntry: Sendable, Equatable {
    let id: UUID
    let persistentModelID: PersistentIdentifier
    let entryDate: Date
    let createdAt: Date
    let isAllDay: Bool
    let rowTitle: String
    let rowSubtitle: String?
    let previewFiles: [String]
    let photoCount: Int
    let searchableTitle: String
    let searchableBody: String

    init(_ entry: JournalEntry) {
        id = entry.id; persistentModelID = entry.persistentModelID
        entryDate = entry.entryDate; createdAt = entry.createdAt; isAllDay = entry.isAllDay
        let blocks = entry.orderedBlocks
        let body = blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        let photos = blocks.filter { $0.kind == .photoGroup }.flatMap(\.orderedPhotos)
        searchableTitle = entry.title; searchableBody = body
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        rowTitle = !title.isEmpty ? title : (!trimmedBody.isEmpty ? String(trimmedBody.prefix(512)) :
            (photos.isEmpty ? String(localized: "Untitled Entry") : String(localized: "Photo Entry")))
        rowSubtitle = title.isEmpty || trimmedBody.isEmpty ? nil : String(trimmedBody.prefix(512))
        previewFiles = photos.prefix(3).map(\.fileName); photoCount = photos.count
    }
}

struct TimelineDay: Sendable {
    let date: Date
    let entries: [TimelineEntry]
}

struct TimelineResult: Sendable {
    let totalCount: Int
    let days: [TimelineDay]
}

/// The Calendar View's months, oldest first, from the month of the earliest Entry Date to the current month.
struct MonthCalendar: Sendable, Equatable {
    let months: [CalendarMonth]
}

struct CalendarMonth: Sendable, Equatable {
    /// The first moment of the month.
    let start: Date
    /// Grid cells before day 1, counted from the calendar's first weekday.
    let leadingEmptyDays: Int
    let days: [CalendarDay]
}

struct CalendarDay: Sendable, Equatable {
    enum State: Sendable { case hasEntries, noEntries, future }
    /// The first moment of the day.
    let date: Date
    let number: Int
    let state: State
    let isToday: Bool
    /// The day's entries in timeline order.
    let entryIDs: [UUID]
    var entryCount: Int { entryIDs.count }
}

/// SwiftData objects stay on this actor. Only immutable display values cross to UIKit.
actor TimelineRepository {
    private let container: ModelContainer
    private var entries: [TimelineEntry] = []
    init(container: ModelContainer) { self.container = container }

    func reload() throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let models = try context.fetch(FetchDescriptor<JournalEntry>())
        var result: [TimelineEntry] = []
        result.reserveCapacity(models.count)
        for model in models {
            try Task.checkCancellation()
            result.append(TimelineEntry(model))
        }
        entries = result
    }

    func update(id: UUID) throws {
        let context = ModelContext(container)
        let updated = try context.entry(id: id).map(TimelineEntry.init)
        entries.removeAll { $0.id == id }
        if let updated { entries.append(updated) }
    }

    func search(_ query: String, calendar: Calendar = .current) throws -> TimelineResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = try entries.filter { entry in
            try Task.checkCancellation()
            return query.isEmpty || entry.searchableTitle.localizedCaseInsensitiveContains(query) || entry.searchableBody.localizedCaseInsensitiveContains(query)
        }
        let days = Self.days(of: matches, calendar: calendar).sorted { $0.date > $1.date }
        return TimelineResult(totalCount: entries.count, days: days)
    }

    func monthCalendar(calendar: Calendar = .current, now: Date = .now) throws -> MonthCalendar {
        let byDay = Dictionary(uniqueKeysWithValues: Self.days(of: entries, calendar: calendar).map { ($0.date, $0.entries) })
        let today = calendar.startOfDay(for: now)
        let current = calendar.dateInterval(of: .month, for: now)!.start
        let earliest = entries.map(\.entryDate).min().map { calendar.dateInterval(of: .month, for: $0)!.start }
        var months: [CalendarMonth] = []
        var month = min(earliest ?? current, current)
        while month <= current {
            try Task.checkCancellation()
            let count = calendar.range(of: .day, in: .month, for: month)!.count
            let days = (0..<count).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: month)!
                let ids = date > today ? [] : byDay[date]?.map(\.id) ?? []
                return CalendarDay(date: date, number: offset + 1,
                                   state: date > today ? .future : ids.isEmpty ? .noEntries : .hasEntries,
                                   isToday: date == today, entryIDs: ids)
            }
            let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
            months.append(CalendarMonth(start: month, leadingEmptyDays: leading, days: days))
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        return MonthCalendar(months: months)
    }

    /// Groups entries by day in timeline order: timed entries latest first, then All-day Entries latest created first.
    private static func days(of entries: [TimelineEntry], calendar: Calendar) -> [TimelineDay] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.entryDate) }
            .map { day, values in
                TimelineDay(date: day, entries: values.sorted {
                    if $0.isAllDay != $1.isAllDay { return !$0.isAllDay }
                    if $0.isAllDay || $0.entryDate == $1.entryDate {
                        if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.entryDate > $1.entryDate
                })
            }
    }
}
