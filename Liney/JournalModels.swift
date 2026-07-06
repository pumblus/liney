import Foundation
import SwiftData

@Model
final class JournalEntry: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var entryDate: Date
    var isAllDay: Bool = false
    var createdAt: Date
    var updatedAt: Date
    var locationName: String?
    var locationLatitude: Double?
    var locationLongitude: Double?
    @Relationship(deleteRule: .cascade, inverse: \EntryBlock.entry) var blocks: [EntryBlock]

    init(
        id: UUID = UUID(),
        title: String = "",
        entryDate: Date = .now,
        isAllDay: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        locationName: String? = nil,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil,
        blocks: [EntryBlock] = []
    ) {
        self.id = id
        self.title = title
        self.entryDate = isAllDay ? Calendar.current.startOfDay(for: entryDate) : entryDate
        self.isAllDay = isAllDay
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.locationName = locationName
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
        self.blocks = blocks
    }
}

@Model
final class EntryBlock: Identifiable {
    @Attribute(.unique) var id: UUID
    var kind: EntryBlockKind
    var sortIndex: Int
    var text: String
    var entry: JournalEntry?

    init(
        id: UUID = UUID(),
        kind: EntryBlockKind = .text,
        sortIndex: Int = 0,
        text: String = "",
        entry: JournalEntry? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sortIndex = sortIndex
        self.text = text
        self.entry = entry
    }
}

enum EntryBlockKind: String, Codable {
    case text
}

extension JournalEntry {
    var textBlocks: [EntryBlock] {
        blocks
            .filter { $0.kind == .text }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    var plainTextBody: String {
        textBlocks.map(\.text).joined(separator: "\n")
    }

    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var rowTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let trimmedBody = plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBody.isEmpty ? String(localized: "Untitled Entry") : trimmedBody
    }

    var rowSubtitle: String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty || trimmedBody.isEmpty ? nil : trimmedBody
    }

    var locationDisplayText: String? {
        let trimmedLocation = locationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedLocation.isEmpty ? nil : trimmedLocation
    }

    func setAllDay(_ allDay: Bool, calendar: Calendar = .current) {
        isAllDay = allDay
        if allDay {
            entryDate = calendar.startOfDay(for: entryDate)
        }
    }

    func setEntryDate(_ date: Date, calendar: Calendar = .current) {
        entryDate = isAllDay ? calendar.startOfDay(for: date) : date
    }

    func setBody(_ body: String, in context: ModelContext) {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textBlocks.forEach { context.delete($0) }
            return
        }

        if let block = textBlocks.first {
            block.text = body
            textBlocks.dropFirst().forEach { context.delete($0) }
        } else {
            let block = EntryBlock(sortIndex: 0, text: body, entry: self)
            blocks.append(block)
            context.insert(block)
        }
    }
}

struct EntryDayGroup: Identifiable {
    let id: Date
    let date: Date
    let entries: [JournalEntry]
}

func searchJournalEntries(_ entries: [JournalEntry], matching query: String) -> [JournalEntry] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return entries }

    return entries.filter { entry in
        entry.title.localizedCaseInsensitiveContains(trimmedQuery) ||
        entry.plainTextBody.localizedCaseInsensitiveContains(trimmedQuery)
    }
}

func groupEntriesByDay(_ entries: [JournalEntry], calendar: Calendar = .current) -> [EntryDayGroup] {
    Dictionary(grouping: entries) { entry in
        calendar.startOfDay(for: entry.entryDate)
    }
    .map { day, entries in
        EntryDayGroup(
            id: day,
            date: day,
            entries: entries.sorted {
                if $0.isAllDay != $1.isAllDay {
                    return !$0.isAllDay
                }
                if $0.isAllDay {
                    return $0.createdAt > $1.createdAt
                }
                if $0.entryDate == $1.entryDate {
                    return $0.createdAt > $1.createdAt
                }
                return $0.entryDate > $1.entryDate
            }
        )
    }
    .sorted { $0.date > $1.date }
}

@discardableResult
func discardBlankNewEntry(_ entry: JournalEntry, in context: ModelContext) -> Bool {
    guard entry.isBlank else { return false }
    context.delete(entry)
    return true
}
