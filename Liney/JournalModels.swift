import CoreLocation
import Foundation
import SwiftData

@Model
final class JournalEntry: Identifiable {
    @Attribute(.unique) var id: UUID
    var externalSourceID: String?
    var dayOnePendingPhotos: Data? = nil
    var title: String
    var entryDate: Date
    var isAllDay: Bool = false
    var createdAt: Date
    var updatedAt: Date
    var locationName: String?
    var locationLatitude: Double?
    var locationLongitude: Double?
    var hasShownPhotoInfoPrompt: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \EntryBlock.entry) var blocks: [EntryBlock]

    init(
        id: UUID = UUID(),
        externalSourceID: String? = nil,
        title: String = "",
        entryDate: Date = .now,
        isAllDay: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        locationName: String? = nil,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil,
        hasShownPhotoInfoPrompt: Bool = false,
        blocks: [EntryBlock] = []
    ) {
        self.id = id
        self.externalSourceID = externalSourceID
        self.title = title
        self.entryDate = isAllDay ? Calendar.current.startOfDay(for: entryDate) : entryDate
        self.isAllDay = isAllDay
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.locationName = locationName
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
        self.hasShownPhotoInfoPrompt = hasShownPhotoInfoPrompt
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
        hasVisibleMetadata || hasLocationCoordinates
    }

    var hasLocationCoordinates: Bool {
        locationLatitude != nil && locationLongitude != nil
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

    var plainTextBody: String {
        textBlocks.map(\.text).joined(separator: "\n")
    }

    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        photoCount == 0
    }

    var locationDisplayText: String? {
        let trimmedLocation = locationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedLocation.isEmpty ? nil : trimmedLocation
    }

    func photoInfoPromptCandidate(from photos: [EntryPhoto]) -> EntryPhoto? {
        guard let firstPhoto = photos.first,
              shouldPromptForPhotoInfo(from: firstPhoto) else { return nil }
        return firstPhoto
    }

    func shouldPromptForPhotoInfo(from photo: EntryPhoto) -> Bool {
        guard !hasShownPhotoInfoPrompt else { return false }

        if let capturedAt = photo.capturedAt,
           abs(capturedAt.timeIntervalSince(entryDate)) > Self.photoInfoPromptTimeInterval {
            return true
        }

        if locationDisplayText == nil {
            return photo.placeDisplayText != nil || photo.hasLocationCoordinates
        }

        guard let entryLocation, let photoLocation = photo.location else { return false }
        return entryLocation.distance(from: photoLocation) > Self.photoInfoPromptDistanceMeters
    }

    func setAllDay(_ allDay: Bool, calendar: Calendar = .current, now: Date = .now) {
        guard allDay != isAllDay else { return }
        isAllDay = allDay
        if allDay {
            entryDate = calendar.startOfDay(for: entryDate)
        } else {
            let time = calendar.dateComponents([.hour, .minute], from: now)
            entryDate = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                      second: 0, of: entryDate) ?? entryDate
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
        } else if photo.hasLocationCoordinates {
            locationName = nil
            locationLatitude = photo.locationLatitude
            locationLongitude = photo.locationLongitude
        }
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

    private static let photoInfoPromptTimeInterval: TimeInterval = 12 * 60 * 60
    private static let photoInfoPromptDistanceMeters: CLLocationDistance = 1_000

    private var entryLocation: CLLocation? {
        guard let locationLatitude, let locationLongitude else { return nil }
        return CLLocation(latitude: locationLatitude, longitude: locationLongitude)
    }
}

private extension EntryPhoto {
    var location: CLLocation? {
        guard let locationLatitude, let locationLongitude else { return nil }
        return CLLocation(latitude: locationLatitude, longitude: locationLongitude)
    }
}

func photoGroupColumnCount(forPhotoCount count: Int) -> Int {
    if count <= 1 { return 1 }
    if count == 4 { return 2 }
    return min(count, 3)
}

@discardableResult
func discardBlankNewEntry(_ entry: JournalEntry, in context: ModelContext) -> Bool {
    guard entry.isBlank else { return false }
    context.delete(entry)
    return true
}

/// SwiftData's rollback reverts attributes but can leave a rolled-back insert in an already
/// loaded relationship, so the entry is fetched again to reload its blocks from the store.
@MainActor
func rollBackChanges(to entry: JournalEntry, in context: ModelContext) {
    context.rollback()
    let id = entry.id
    _ = try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == id }))
}

@MainActor
func saveEntryChanges(
    _ entry: JournalEntry,
    in context: ModelContext,
    discardIfBlank: Bool = false,
    save: (() throws -> Void)? = nil
) throws {
    entry.normalizeBlocks(in: context)
    entry.updatedAt = .now
    let discarded = discardIfBlank && discardBlankNewEntry(entry, in: context)
    do {
        try (save ?? { try context.save() })()
    } catch {
        if discarded { context.rollback() }
        throw error
    }
}

@MainActor
func deleteEntryAndSave(
    _ entry: JournalEntry,
    in context: ModelContext,
    save: (() throws -> Void)? = nil
) throws -> [String] {
    let fileNames = entry.photoGroupBlocks.flatMap { $0.orderedPhotos.map(\.fileName) }
    context.delete(entry)
    do {
        try (save ?? { try context.save() })()
        return fileNames
    } catch {
        rollBackChanges(to: entry, in: context)
        throw error
    }
}
