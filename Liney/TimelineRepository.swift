import Foundation
import SwiftData

struct TimelineEntry: Sendable {
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
        let descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == id })
        let updated = try context.fetch(descriptor).first.map(TimelineEntry.init)
        entries.removeAll { $0.id == id }
        if let updated { entries.append(updated) }
    }

    func search(_ query: String, calendar: Calendar = .current) throws -> TimelineResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = try entries.filter { entry in
            try Task.checkCancellation()
            return query.isEmpty || entry.searchableTitle.localizedCaseInsensitiveContains(query) || entry.searchableBody.localizedCaseInsensitiveContains(query)
        }
        let days = Dictionary(grouping: matches) { calendar.startOfDay(for: $0.entryDate) }
            .map { day, values in
                TimelineDay(date: day, entries: values.sorted {
                    if $0.isAllDay != $1.isAllDay { return !$0.isAllDay }
                    if $0.isAllDay || $0.entryDate == $1.entryDate {
                        if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.entryDate > $1.entryDate
                })
            }.sorted { $0.date > $1.date }
        return TimelineResult(totalCount: entries.count, days: days)
    }
}
