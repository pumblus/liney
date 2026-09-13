import Foundation
import SwiftData
import ZIPFoundation

struct DayOneImportPlan: Identifiable, Equatable {
    let id = UUID()
    let archiveURL: URL
    let entryCount: Int
    let photoCount: Int
    let unsupportedMediaCount: Int
}

struct DayOneImportProgress: Equatable {
    let processedEntries: Int
    let totalEntries: Int
}

struct DayOneImportSummary: Equatable {
    var importedEntries = 0
    var skippedDuplicates = 0
    var failedEntries = 0
    var skippedMedia = 0
    var processedEntries = 0
    var totalEntries = 0
    var wasCancelled = false
}

enum DayOneImportError: LocalizedError {
    case unreadableArchive
    case missingDayOneJSON

    var errorDescription: String? {
        switch self {
        case .unreadableArchive:
            String(localized: "The selected file is not a readable Day One JSON zip.")
        case .missingDayOneJSON:
            String(localized: "No Day One entries were found in the selected zip.")
        }
    }
}

struct DayOneImporter {
    private let fileManager: FileManager
    private let photoStorage: PhotoStorage

    init(fileManager: FileManager = .default, photoStorage: PhotoStorage = PhotoStorage()) {
        self.fileManager = fileManager
        self.photoStorage = photoStorage
    }

    func prepareImport(from sourceURL: URL) throws -> DayOneImportPlan {
        let temporaryURL = try copyToTemporaryArchive(sourceURL)

        do {
            let plan = try preflightArchive(at: temporaryURL)
            return plan
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    func deleteTemporaryArchive(_ plan: DayOneImportPlan) {
        try? fileManager.removeItem(at: plan.archiveURL)
    }

    @MainActor
    func importPreparedArchive(
        _ plan: DayOneImportPlan,
        into context: ModelContext,
        progress: (DayOneImportProgress) -> Void
    ) async -> DayOneImportSummary {
        defer { deleteTemporaryArchive(plan) }

        var summary = DayOneImportSummary(totalEntries: plan.entryCount)

        do {
            let archive = try Archive(url: plan.archiveURL, accessMode: .read, pathEncoding: nil)
            let archiveContents = try await archiveContentsOffMain(in: archive)
            let documents = archiveContents.documents
            guard !documents.isEmpty else { throw DayOneImportError.missingDayOneJSON }

            let archiveEntries = archiveContents.entriesByPath
            var existingSourceIDs = try existingExternalSourceIDs(in: context)
            progress(DayOneImportProgress(processedEntries: 0, totalEntries: plan.entryCount))

            for rawEntry in documents.flatMap(\.entries) {
                if Task.isCancelled {
                    summary.wasCancelled = true
                    break
                }

                await importEntry(
                    rawEntry,
                    archive: archive,
                    archiveEntries: archiveEntries,
                    existingSourceIDs: &existingSourceIDs,
                    context: context,
                    summary: &summary
                )

                summary.processedEntries += 1
                progress(DayOneImportProgress(
                    processedEntries: summary.processedEntries,
                    totalEntries: plan.entryCount
                ))
                await Task.yield()
            }
        } catch {
            summary.failedEntries += max(1, plan.entryCount - summary.processedEntries)
        }

        return summary
    }

    private func copyToTemporaryArchive(_ sourceURL: URL) throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("LineyImports", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let destinationURL = directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func preflightArchive(at archiveURL: URL) throws -> DayOneImportPlan {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read, pathEncoding: nil) else {
            throw DayOneImportError.unreadableArchive
        }

        let documents = try dayOneDocuments(in: archive)
        guard !documents.isEmpty else {
            throw DayOneImportError.missingDayOneJSON
        }

        let entries = documents.flatMap(\.entries)
        guard !entries.isEmpty else {
            throw DayOneImportError.missingDayOneJSON
        }

        return DayOneImportPlan(
            archiveURL: archiveURL,
            entryCount: entries.count,
            photoCount: entries.reduce(0) { $0 + photoDictionaries(in: $1).count },
            unsupportedMediaCount: entries.reduce(0) { $0 + unsupportedMediaCount(in: $1) }
        )
    }

    @MainActor
    private func importEntry(
        _ rawEntry: JSONObject,
        archive: Archive,
        archiveEntries: [String: Entry],
        existingSourceIDs: inout Set<String>,
        context: ModelContext,
        summary: inout DayOneImportSummary
    ) async {
        guard let sourceID = trimmedString(rawEntry["uuid"]) else {
            summary.failedEntries += 1
            summary.skippedMedia += unsupportedMediaCount(in: rawEntry)
            return
        }

        guard !existingSourceIDs.contains(sourceID) else {
            summary.skippedDuplicates += 1
            return
        }

        var copiedFileNames: [String] = []

        do {
            let result = try await buildEntryDataOffMain(
                from: rawEntry,
                sourceID: sourceID,
                archive: archive,
                archiveEntries: archiveEntries
            )
            copiedFileNames = result.copiedFileNames
            context.insert(makeEntry(from: result.entry, in: context))
            try context.save()
            existingSourceIDs.insert(sourceID)
            summary.importedEntries += 1
            summary.skippedMedia += result.skippedMedia
        } catch let error as DayOneEntryBuildError {
            summary.failedEntries += 1
            summary.skippedMedia += error.skippedMedia
            deleteCopiedPhotos(error.copiedFileNames)
        } catch {
            context.rollback()
            summary.failedEntries += 1
            deleteCopiedPhotos(copiedFileNames)
        }
    }

    private func buildEntryDataOffMain(
        from rawEntry: JSONObject,
        sourceID: String,
        archive: Archive,
        archiveEntries: [String: Entry]
    ) async throws -> DayOneBuiltEntry {
        try await withThrowingTaskGroup(of: DayOneBuiltEntry.self) { group in
            group.addTask(priority: .userInitiated) {
                try buildEntryData(
                    from: rawEntry,
                    sourceID: sourceID,
                    archive: archive,
                    archiveEntries: archiveEntries
                )
            }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func archiveContentsOffMain(in archive: Archive) async throws -> DayOneArchiveContents {
        try await withThrowingTaskGroup(of: DayOneArchiveContents.self) { group in
            group.addTask(priority: .userInitiated) {
                DayOneArchiveContents(
                    documents: try dayOneDocuments(in: archive),
                    entriesByPath: entriesByPath(in: archive)
                )
            }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func buildEntryData(
        from rawEntry: JSONObject,
        sourceID: String,
        archive: Archive,
        archiveEntries: [String: Entry]
    ) throws -> DayOneBuiltEntry {
        guard let creationDate = dateValue(rawEntry["creationDate"]) else {
            throw DayOneEntryBuildError(skippedMedia: unsupportedMediaCount(in: rawEntry))
        }

        let location = DayOneLocation(rawEntry["location"] as? JSONObject)
        let text = stringValue(rawEntry["text"]) ?? ""
        let photos = dayOnePhotos(in: rawEntry)
        let blockResult = try importedBlocks(
            text: text,
            photos: photos,
            archive: archive,
            archiveEntries: archiveEntries
        )

        guard blockResult.blocks.contains(where: \.hasContent) else {
            throw DayOneEntryBuildError(
                skippedMedia: blockResult.skippedMedia + unsupportedMediaCount(in: rawEntry),
                copiedFileNames: blockResult.copiedFileNames
            )
        }

        let modifiedDate = dateValue(rawEntry["modifiedDate"]) ?? creationDate
        let allDay = allDayValue(rawEntry, creationDate: creationDate)
        let entry = DayOneEntryData(
            externalSourceID: sourceID,
            title: stringValue(rawEntry["title"]) ?? "",
            entryDate: allDay.entryDate,
            isAllDay: allDay.isAllDay,
            createdAt: creationDate,
            updatedAt: modifiedDate,
            locationName: location.displayName,
            locationLatitude: location.latitude,
            locationLongitude: location.longitude,
            blocks: blockResult.blocks
        )

        return DayOneBuiltEntry(
            entry: entry,
            skippedMedia: blockResult.skippedMedia + unsupportedMediaCount(in: rawEntry),
            copiedFileNames: blockResult.copiedFileNames
        )
    }

    @MainActor
    private func makeEntry(from data: DayOneEntryData, in context: ModelContext) -> JournalEntry {
        let entry = JournalEntry(
            externalSourceID: data.externalSourceID,
            title: data.title,
            entryDate: data.entryDate,
            isAllDay: data.isAllDay,
            createdAt: data.createdAt,
            updatedAt: data.updatedAt,
            locationName: data.locationName,
            locationLatitude: data.locationLatitude,
            locationLongitude: data.locationLongitude
        )

        for (index, block) in data.blocks.enumerated() {
            switch block {
            case .text(let text):
                let entryBlock = EntryBlock(kind: .text, sortIndex: index, text: text, entry: entry)
                entry.blocks.append(entryBlock)
                context.insert(entryBlock)
            case .photoGroup(let photos):
                let entryBlock = EntryBlock(kind: .photoGroup, sortIndex: index, entry: entry)
                let entryPhotos = photos.enumerated().map { order, photo in
                    EntryPhoto(
                        fileName: photo.fileName,
                        displayOrder: order,
                        capturedAt: photo.capturedAt,
                        placeName: photo.placeName,
                        locationLatitude: photo.locationLatitude,
                        locationLongitude: photo.locationLongitude,
                        block: entryBlock
                    )
                }
                entryBlock.photos = entryPhotos
                entry.blocks.append(entryBlock)
                context.insert(entryBlock)
                entryPhotos.forEach { context.insert($0) }
            }
        }
        entry.normalizeBlocks(in: context)

        return entry
    }

    private func importedBlocks(
        text: String,
        photos: [DayOnePhoto],
        archive: Archive,
        archiveEntries: [String: Entry]
    ) throws -> DayOneBlockImportResult {
        let matches = Self.momentRegex.matches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )

        if matches.isEmpty {
            return try fallbackBlocks(
                text: text,
                photos: photos,
                archive: archive,
                archiveEntries: archiveEntries
            )
        }

        var blocks: [ImportedEntryBlock] = []
        var usedPhotoIndexes = Set<Int>()
        var pendingPhotos: [PhotoGroupItem] = []
        var skippedMedia = 0
        var copiedFileNames: [String] = []
        var previousLocation = 0
        let nsText = text as NSString
        let photosByKey = indexedPhotosByKey(photos)

        func flushPhotos() {
            guard !pendingPhotos.isEmpty else { return }
            blocks.append(.photoGroup(pendingPhotos))
            pendingPhotos.removeAll()
        }

        func appendText(_ range: NSRange) {
            guard range.length > 0 else { return }
            let value = nsText.substring(with: range)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            flushPhotos()
            blocks.append(.text(value))
        }

        for match in matches {
            appendText(NSRange(location: previousLocation, length: match.range.location - previousLocation))
            previousLocation = match.range.location + match.range.length

            guard match.numberOfRanges > 1 else {
                skippedMedia += 1
                continue
            }

            let key = nsText.substring(with: match.range(at: 1)).lowercased()
            guard let photoIndex = photosByKey[key], !usedPhotoIndexes.contains(photoIndex) else {
                skippedMedia += 1
                continue
            }

            usedPhotoIndexes.insert(photoIndex)
            do {
                let item = try importPhoto(photos[photoIndex], archive: archive, archiveEntries: archiveEntries)
                pendingPhotos.append(item)
                copiedFileNames.append(item.fileName)
            } catch {
                skippedMedia += 1
            }
        }

        appendText(NSRange(location: previousLocation, length: nsText.length - previousLocation))
        flushPhotos()

        let remainingPhotos = photos
            .filter { !usedPhotoIndexes.contains($0.index) }
            .sorted { ($0.orderInEntry ?? $0.index) < ($1.orderInEntry ?? $1.index) }
        let remainingResult = try importPhotoGroup(
            remainingPhotos,
            archive: archive,
            archiveEntries: archiveEntries
        )
        if !remainingResult.photos.isEmpty {
            blocks.append(.photoGroup(remainingResult.photos))
        }
        skippedMedia += remainingResult.skippedMedia
        copiedFileNames.append(contentsOf: remainingResult.copiedFileNames)

        return DayOneBlockImportResult(
            blocks: blocks,
            skippedMedia: skippedMedia,
            copiedFileNames: copiedFileNames
        )
    }

    private func fallbackBlocks(
        text: String,
        photos: [DayOnePhoto],
        archive: Archive,
        archiveEntries: [String: Entry]
    ) throws -> DayOneBlockImportResult {
        var blocks: [ImportedEntryBlock] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(text))
        }

        let result = try importPhotoGroup(
            photos.sorted { ($0.orderInEntry ?? $0.index) < ($1.orderInEntry ?? $1.index) },
            archive: archive,
            archiveEntries: archiveEntries
        )
        if !result.photos.isEmpty {
            blocks.append(.photoGroup(result.photos))
        }

        return DayOneBlockImportResult(
            blocks: blocks,
            skippedMedia: result.skippedMedia,
            copiedFileNames: result.copiedFileNames
        )
    }

    private func importPhotoGroup(
        _ photos: [DayOnePhoto],
        archive: Archive,
        archiveEntries: [String: Entry]
    ) throws -> (photos: [PhotoGroupItem], skippedMedia: Int, copiedFileNames: [String]) {
        var importedPhotos: [PhotoGroupItem] = []
        var skippedMedia = 0
        var copiedFileNames: [String] = []

        for photo in photos {
            do {
                let item = try importPhoto(photo, archive: archive, archiveEntries: archiveEntries)
                importedPhotos.append(item)
                copiedFileNames.append(item.fileName)
            } catch {
                skippedMedia += 1
            }
        }

        return (importedPhotos, skippedMedia, copiedFileNames)
    }

    private func importPhoto(
        _ photo: DayOnePhoto,
        archive: Archive,
        archiveEntries: [String: Entry]
    ) throws -> PhotoGroupItem {
        guard let entry = archiveEntry(for: photo, in: archiveEntries) else {
            throw DayOneEntryBuildError(skippedMedia: 1)
        }

        let data = try extractChecked(entry, from: archive)

        let saved = try photoStorage.saveJPEGWithMetadata(from: data)
        return PhotoGroupItem(
            fileName: saved.fileName,
            capturedAt: saved.capturedAt ?? photo.capturedAt,
            placeName: photo.location.displayName ?? saved.placeName,
            locationLatitude: saved.locationLatitude ?? photo.location.latitude,
            locationLongitude: saved.locationLongitude ?? photo.location.longitude
        )
    }

    private func archiveEntry(for photo: DayOnePhoto, in entries: [String: Entry]) -> Entry? {
        for path in photo.candidatePaths {
            if let entry = entries[normalizePath(path)] {
                return entry
            }
            if let entry = entries[normalizePath("photos/\(path)")] {
                return entry
            }
        }

        let lookupKeys = Set(photo.lookupKeys)
        return entries.first { path, _ in
            guard path.contains("photos/") else { return false }
            let lastComponent = (path as NSString).lastPathComponent
            let stem = ((lastComponent as NSString).deletingPathExtension).lowercased()
            return lookupKeys.contains(stem)
        }?.value
    }

    private func dayOneDocuments(in archive: Archive) throws -> [DayOneDocument] {
        var documents: [DayOneDocument] = []

        for entry in archive {
            guard entry.type == .file,
                  entry.path.lowercased().hasSuffix(".json") else { continue }

            let data = try extractChecked(entry, from: archive)

            guard let root = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
                  let entries = root["entries"] as? [JSONObject] else { continue }

            documents.append(DayOneDocument(entries: entries))
        }

        return documents
    }

    private func entriesByPath(in archive: Archive) -> [String: Entry] {
        archive.reduce(into: [:]) { result, entry in
            result[normalizePath(entry.path)] = entry
        }
    }

    private func extractChecked(_ entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        let checksum = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        guard checksum == entry.checksum else {
            throw Archive.ArchiveError.invalidCRC32
        }
        return data
    }

    @MainActor
    private func existingExternalSourceIDs(in context: ModelContext) throws -> Set<String> {
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        return Set(entries.compactMap { trimmedString($0.externalSourceID) })
    }

    @MainActor
    private func deleteCopiedPhotos(_ fileNames: [String]) {
        for fileName in fileNames {
            try? photoStorage.delete(fileName: fileName)
        }
    }

    private func dayOnePhotos(in rawEntry: JSONObject) -> [DayOnePhoto] {
        photoDictionaries(in: rawEntry).enumerated().map { index, rawPhoto in
            DayOnePhoto(index: index, rawPhoto: rawPhoto)
        }
    }

    private func photoDictionaries(in rawEntry: JSONObject) -> [JSONObject] {
        rawEntry["photos"] as? [JSONObject] ?? []
    }

    private func unsupportedMediaCount(in rawEntry: JSONObject) -> Int {
        let arrayKeys = ["videos", "audios", "audio", "pdfs", "attachments", "files"]
        let arrayCount = arrayKeys.reduce(0) { count, key in
            count + ((rawEntry[key] as? [Any])?.count ?? 0)
        }
        let metadataKeys = ["weather", "music", "activity", "steps"]
        let metadataCount = metadataKeys.reduce(0) { count, key in
            count + (rawEntry[key] == nil ? 0 : 1)
        }
        let tagCount = (rawEntry["tags"] as? [Any])?.count ?? 0
        return arrayCount + metadataCount + tagCount
    }

    private func indexedPhotosByKey(_ photos: [DayOnePhoto]) -> [String: Int] {
        photos.reduce(into: [:]) { result, photo in
            for key in photo.lookupKeys where result[key] == nil {
                result[key] = photo.index
            }
        }
    }

    private func allDayValue(_ rawEntry: JSONObject, creationDate: Date) -> (isAllDay: Bool, entryDate: Date) {
        guard boolValue(rawEntry["isAllDay"]) == true else { return (false, creationDate) }

        var sourceCalendar = Calendar(identifier: .gregorian)
        if let timeZoneID = stringValue(rawEntry["timeZone"]),
           let timeZone = TimeZone(identifier: timeZoneID) {
            sourceCalendar.timeZone = timeZone
        }

        let sourceDateComponents = sourceCalendar.dateComponents(
            [.year, .month, .day],
            from: creationDate
        )
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = Calendar.current.timeZone
        let deviceDate = deviceCalendar.date(from: sourceDateComponents) ??
            deviceCalendar.startOfDay(for: creationDate)
        return (true, deviceDate)
    }

    private func normalizePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private func trimmedString(_ value: Any?) -> String? {
        guard let value = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            if value == "true" { return true }
            if value == "false" { return false }
        }
        return nil
    }

    private func dateValue(_ value: Any?) -> Date? {
        guard let text = stringValue(value) else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: text)
    }

    private static let momentRegex = try! NSRegularExpression(
        pattern: #"dayone-moment://([A-Za-z0-9_-]+)"#
    )

    private typealias JSONObject = [String: Any]

    private struct DayOneDocument {
        let entries: [JSONObject]
    }

    private struct DayOnePhoto {
        let index: Int
        let identifier: String?
        let md5: String?
        let fileName: String?
        let type: String?
        let orderInEntry: Int?
        let capturedAt: Date?
        let location: DayOneLocation

        init(index: Int, rawPhoto: JSONObject) {
            self.index = index
            identifier = Self.trimmed(rawPhoto["identifier"])
            md5 = Self.trimmed(rawPhoto["md5"])
            fileName = Self.trimmed(rawPhoto["filename"]) ?? Self.trimmed(rawPhoto["fileName"])
            type = Self.trimmed(rawPhoto["type"]) ?? Self.trimmed(rawPhoto["extension"])
            orderInEntry = Self.integer(rawPhoto["orderInEntry"])
            capturedAt = Self.date(rawPhoto["date"]) ?? Self.date(rawPhoto["creationDate"])
            location = DayOneLocation(rawPhoto["location"] as? JSONObject ?? rawPhoto)
        }

        var lookupKeys: [String] {
            [identifier, md5, fileName.map { (($0 as NSString).deletingPathExtension) }]
                .compactMap { $0?.lowercased() }
        }

        var candidatePaths: [String] {
            var paths: [String] = []
            if let fileName {
                paths.append(fileName)
            }

            let extensions = candidateExtensions
            for key in [identifier, md5].compactMap({ $0 }) {
                for fileExtension in extensions {
                    paths.append("\(key).\(fileExtension)")
                }
            }
            return paths
        }

        private var candidateExtensions: [String] {
            let raw = type?.lowercased()
                .replacingOccurrences(of: "public.", with: "")
                .replacingOccurrences(of: "image/", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))

            switch raw {
            case "jpeg", "jpg":
                return ["jpg", "jpeg"]
            case let value? where !value.isEmpty:
                return [value]
            default:
                return ["jpg", "jpeg", "png", "heic"]
            }
        }

        private static func trimmed(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func integer(_ value: Any?) -> Int? {
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) }
            return nil
        }

        private static func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
    }

    private struct DayOneLocation {
        let displayName: String?
        let latitude: Double?
        let longitude: Double?

        init(_ rawLocation: JSONObject?) {
            guard let rawLocation else {
                displayName = nil
                latitude = nil
                longitude = nil
                return
            }

            latitude = Self.number(rawLocation["latitude"])
            longitude = Self.number(rawLocation["longitude"])

            let explicitName = Self.firstTrimmedString([
                rawLocation["userLabel"],
                rawLocation["placeName"],
                rawLocation["name"]
            ])
            if let explicitName {
                displayName = explicitName
            } else {
                let parts = [
                    Self.trimmed(rawLocation["localityName"]),
                    Self.trimmed(rawLocation["administrativeArea"]),
                    Self.trimmed(rawLocation["country"])
                ].compactMap { $0 }
                displayName = parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
        }

        private static func firstTrimmedString(_ values: [Any?]) -> String? {
            values.compactMap(trimmed).first
        }

        private static func trimmed(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func number(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? String { return Double(value) }
            return nil
        }
    }

    private enum ImportedEntryBlock {
        case text(String)
        case photoGroup([PhotoGroupItem])

        var hasContent: Bool {
            switch self {
            case .text(let text):
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .photoGroup(let photos):
                !photos.isEmpty
            }
        }
    }

    private struct DayOneBlockImportResult {
        let blocks: [ImportedEntryBlock]
        let skippedMedia: Int
        let copiedFileNames: [String]
    }

    private struct DayOneBuiltEntry {
        let entry: DayOneEntryData
        let skippedMedia: Int
        let copiedFileNames: [String]
    }

    private struct DayOneArchiveContents {
        let documents: [DayOneDocument]
        let entriesByPath: [String: Entry]
    }

    private struct DayOneEntryData {
        let externalSourceID: String
        let title: String
        let entryDate: Date
        let isAllDay: Bool
        let createdAt: Date
        let updatedAt: Date
        let locationName: String?
        let locationLatitude: Double?
        let locationLongitude: Double?
        let blocks: [ImportedEntryBlock]
    }

    private struct DayOneEntryBuildError: Error {
        let skippedMedia: Int
        let copiedFileNames: [String]

        init(skippedMedia: Int, copiedFileNames: [String] = []) {
            self.skippedMedia = skippedMedia
            self.copiedFileNames = copiedFileNames
        }
    }
}
