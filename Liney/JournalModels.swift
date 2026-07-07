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
    @Relationship(deleteRule: .cascade, inverse: \EntryPhoto.block) var photos: [EntryPhoto]

    init(
        id: UUID = UUID(),
        kind: EntryBlockKind = .text,
        sortIndex: Int = 0,
        text: String = "",
        entry: JournalEntry? = nil,
        photos: [EntryPhoto] = []
    ) {
        self.id = id
        self.kind = kind
        self.sortIndex = sortIndex
        self.text = text
        self.entry = entry
        self.photos = photos
    }
}

@Model
final class EntryPhoto: Identifiable {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var displayOrder: Int
    var capturedAt: Date?
    var placeName: String?
    var locationLatitude: Double?
    var locationLongitude: Double?
    var block: EntryBlock?

    init(
        id: UUID = UUID(),
        fileName: String,
        displayOrder: Int = 0,
        capturedAt: Date? = nil,
        placeName: String? = nil,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil,
        block: EntryBlock? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.displayOrder = displayOrder
        self.capturedAt = capturedAt
        self.placeName = placeName
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
        self.block = block
    }
}

enum EntryBlockKind: String, Codable {
    case text
    case photoGroup
}

struct PhotoGroupItem {
    let fileName: String
    let capturedAt: Date?
    let placeName: String?
    let locationLatitude: Double?
    let locationLongitude: Double?

    init(
        fileName: String,
        capturedAt: Date? = nil,
        placeName: String? = nil,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil
    ) {
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.placeName = placeName
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
    }
}

struct PhotoGroupInsertion {
    let photoBlock: EntryBlock
    let followingTextBlock: EntryBlock?
}

extension EntryPhoto {
    var placeDisplayText: String? {
        let trimmedPlace = placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedPlace.isEmpty ? nil : trimmedPlace
    }

    var hasVisibleMetadata: Bool {
        capturedAt != nil || placeDisplayText != nil
    }

    var hasUsableEntryInfo: Bool {
        hasVisibleMetadata
    }
}

extension EntryBlock {
    var orderedPhotos: [EntryPhoto] {
        photos.sorted {
            if $0.displayOrder == $1.displayOrder {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.displayOrder < $1.displayOrder
        }
    }
}

extension JournalEntry {
    var orderedBlocks: [EntryBlock] {
        blocks.sorted {
            if $0.sortIndex == $1.sortIndex {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sortIndex < $1.sortIndex
        }
    }

    var textBlocks: [EntryBlock] {
        orderedBlocks.filter { $0.kind == .text }
    }

    var photoGroupBlocks: [EntryBlock] {
        orderedBlocks.filter { $0.kind == .photoGroup }
    }

    var photoCount: Int {
        photoGroupBlocks.reduce(0) { $0 + $1.photos.count }
    }

    var previewPhotos: [EntryPhoto] {
        photoGroupBlocks.flatMap(\.orderedPhotos).prefix(3).map { $0 }
    }

    var plainTextBody: String {
        textBlocks.map(\.text).joined(separator: "\n")
    }

    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        photoCount == 0
    }

    var rowTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let trimmedBody = plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            return trimmedBody
        }

        return photoCount > 0 ? String(localized: "Photo Entry") : String(localized: "Untitled Entry")
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

    func applyInfo(from photo: EntryPhoto) {
        if let capturedAt = photo.capturedAt {
            isAllDay = false
            entryDate = capturedAt
        }

        if let placeText = photo.placeDisplayText {
            locationName = placeText
            locationLatitude = photo.locationLatitude
            locationLongitude = photo.locationLongitude
        }
    }

    func setBody(_ body: String, in context: ModelContext) {
        let existingTextBlocks = textBlocks
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            existingTextBlocks.forEach { removeBlock($0, in: context) }
            normalizeBlocks(in: context)
            return
        }

        if let block = existingTextBlocks.first {
            block.text = body
            existingTextBlocks.dropFirst().forEach { removeBlock($0, in: context) }
        } else {
            let block = EntryBlock(sortIndex: 0, text: body, entry: self)
            blocks.append(block)
            context.insert(block)
        }
        normalizeBlocks(in: context)
    }

    @discardableResult
    func insertPhotoGroup(
        fileNames: [String],
        focusedTextBlockID: UUID? = nil,
        cursorOffset: Int? = nil,
        in context: ModelContext
    ) -> PhotoGroupInsertion? {
        insertPhotoGroup(
            photos: fileNames.map { PhotoGroupItem(fileName: $0) },
            focusedTextBlockID: focusedTextBlockID,
            cursorOffset: cursorOffset,
            in: context
        )
    }

    @discardableResult
    func insertPhotoGroup(
        photos photoItems: [PhotoGroupItem],
        focusedTextBlockID: UUID? = nil,
        cursorOffset: Int? = nil,
        in context: ModelContext
    ) -> PhotoGroupInsertion? {
        guard !photoItems.isEmpty else { return nil }

        let photoBlock = EntryBlock(kind: .photoGroup, entry: self)
        let photos = photoItems.enumerated().map { index, photo in
            EntryPhoto(
                fileName: photo.fileName,
                displayOrder: index,
                capturedAt: photo.capturedAt,
                placeName: photo.placeName,
                locationLatitude: photo.locationLatitude,
                locationLongitude: photo.locationLongitude,
                block: photoBlock
            )
        }
        photoBlock.photos = photos
        context.insert(photoBlock)
        photos.forEach { context.insert($0) }
        blocks.append(photoBlock)

        var ordered = orderedBlocks.filter { $0.id != photoBlock.id }
        var insertionIndex = ordered.count
        var followingTextBlock: EntryBlock?

        if let focusedTextBlockID,
           let textBlockIndex = ordered.firstIndex(where: { $0.id == focusedTextBlockID && $0.kind == .text }) {
            let textBlock = ordered[textBlockIndex]
            let offset = clampedOffset(cursorOffset ?? textBlock.text.count, in: textBlock.text)
            let splitIndex = textBlock.text.index(textBlock.text.startIndex, offsetBy: offset)
            let before = String(textBlock.text[..<splitIndex])
            let after = String(textBlock.text[splitIndex...])
            let hasBefore = !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasAfter = !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            switch (hasBefore, hasAfter) {
            case (true, true):
                textBlock.text = before
                let afterBlock = EntryBlock(kind: .text, text: after, entry: self)
                context.insert(afterBlock)
                blocks.append(afterBlock)
                insertionIndex = textBlockIndex + 1
                followingTextBlock = afterBlock
            case (true, false):
                textBlock.text = before
                insertionIndex = textBlockIndex + 1
            case (false, true):
                textBlock.text = after
                insertionIndex = textBlockIndex
                followingTextBlock = textBlock
            case (false, false):
                removeBlock(textBlock, in: context)
                ordered.remove(at: textBlockIndex)
                insertionIndex = textBlockIndex
            }
        }

        ordered.insert(photoBlock, at: insertionIndex)
        if let followingTextBlock, !ordered.contains(where: { $0.id == followingTextBlock.id }) {
            ordered.insert(followingTextBlock, at: insertionIndex + 1)
        }
        reindex(ordered)
        return PhotoGroupInsertion(photoBlock: photoBlock, followingTextBlock: followingTextBlock)
    }

    @discardableResult
    func insertTextBlock(_ text: String, after previousBlock: EntryBlock? = nil, in context: ModelContext) -> EntryBlock? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var ordered = orderedBlocks
        let insertionIndex: Int
        if let previousBlock, let previousIndex = ordered.firstIndex(where: { $0.id == previousBlock.id }) {
            insertionIndex = previousIndex + 1
        } else {
            insertionIndex = ordered.endIndex
        }

        let block = EntryBlock(kind: .text, text: text, entry: self)
        context.insert(block)
        blocks.append(block)
        ordered.insert(block, at: min(insertionIndex, ordered.endIndex))
        reindex(ordered)
        return block
    }

    @discardableResult
    func deletePhoto(_ photo: EntryPhoto, in context: ModelContext) -> String {
        let fileName = photo.fileName
        let block = photo.block ?? photoGroupBlocks.first { block in
            block.photos.contains { $0.id == photo.id }
        }
        block?.photos.removeAll { $0.id == photo.id }
        context.delete(photo)
        normalizeBlocks(in: context)
        return fileName
    }

    func normalizeBlocks(in context: ModelContext) {
        var normalized: [EntryBlock] = []

        for block in orderedBlocks {
            switch block.kind {
            case .text:
                guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    removeBlock(block, in: context)
                    continue
                }

                if let previous = normalized.last, previous.kind == .text {
                    previous.text = [previous.text, block.text].joined(separator: "\n")
                    removeBlock(block, in: context)
                } else {
                    normalized.append(block)
                }
            case .photoGroup:
                let photos = block.orderedPhotos
                guard !photos.isEmpty else {
                    removeBlock(block, in: context)
                    continue
                }

                for (index, photo) in photos.enumerated() {
                    photo.displayOrder = index
                }
                normalized.append(block)
            }
        }

        reindex(normalized)
    }

    private func clampedOffset(_ offset: Int, in text: String) -> Int {
        min(max(offset, 0), text.count)
    }

    private func removeBlock(_ block: EntryBlock, in context: ModelContext) {
        blocks.removeAll { $0.id == block.id }
        context.delete(block)
    }

    private func reindex(_ orderedBlocks: [EntryBlock]) {
        for (index, block) in orderedBlocks.enumerated() {
            block.sortIndex = index
            block.entry = self
        }
    }
}

struct PhotoGroupCellLayout: Equatable {
    let columnSpan: Int
    let aspectRatio: Double
}

func photoGroupLayoutPlan(forPhotoCount count: Int) -> [PhotoGroupCellLayout] {
    guard count > 0 else { return [] }

    let columnCount = photoGroupColumnCount(forPhotoCount: count)
    return (0..<count).map { index in
        let columnSpan = count == 3 && index == count - 1 ? columnCount : 1
        return PhotoGroupCellLayout(
            columnSpan: columnSpan,
            aspectRatio: columnSpan == columnCount ? 4.0 / 3.0 : 1
        )
    }
}

func photoGroupColumnCount(forPhotoCount count: Int) -> Int {
    if count <= 1 { return 1 }
    if count <= 4 { return 2 }
    return 3
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
