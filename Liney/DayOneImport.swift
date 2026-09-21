import Foundation
import SwiftData
import ZIPFoundation

struct DayOneImportPlan: Identifiable, Equatable {
    let id = UUID()
    let archiveURL: URL
    let entryCount: Int
    let photoCount: Int
    let unsupportedMediaCount: Int
    var ignoredMetadataCount = 0
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
    var repairedEntries = 0
    var recoveredPhotos = 0
    var failedPhotos = 0
    var ignoredMetadata = 0
    var issues: [DayOneImportIssue] = []
}

struct DayOneImportIssue: Identifiable, Equatable {
    let id = UUID()
    let sourceID: String?
    let entryNumber: Int
    let entryDate: Date?
    let reason: Reason

    enum Reason: String, Equatable {
        case missingIdentity, invalidDate, noContent, photosUnavailable, saveFailed
        case recoveryUnavailable, appendedPhotos, archiveFailed

        var message: String {
            switch self {
            case .missingIdentity: "This entry has no source ID. Check the Day One export."
            case .invalidDate: "This entry has an unreadable date. Check the Day One export."
            case .noContent: "No supported text or readable photos were found. Export again with media included."
            case .photosUnavailable: "Some photos could not be read. Export again with media included and import the zip to retry."
            case .saveFailed: "This entry could not be saved. Check available storage and retry."
            case .recoveryUnavailable: "Photo recovery information could not be read. Existing content was kept."
            case .appendedPhotos: "The original photo position was removed. Recovered photos were added at the end of the entry."
            case .archiveFailed: "The archive could not be read completely. Export again and retry; saved entries are kept."
            }
        }
    }
}

private struct DayOnePendingPhoto: Codable {
    let key: String
    let groupID: UUID
    let photoID: UUID
    let followingPhotoIDs: [UUID]
    let beforeBlockID: UUID?
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
    private let saveContext: @MainActor (ModelContext) throws -> Void

    init(fileManager: FileManager = .default, photoStorage: PhotoStorage = PhotoStorage(),
         saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) {
        self.fileManager = fileManager
        self.photoStorage = photoStorage
        self.saveContext = saveContext
    }

    func prepareImport(from sourceURL: URL) throws -> DayOneImportPlan {
        let temporaryURL = try copyToTemporaryArchive(sourceURL)

        do {
            try Task.checkCancellation()
            let plan = try preflightArchive(at: temporaryURL)
            try Task.checkCancellation()
            return plan
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    func prepareImportInBackground(from sourceURL: URL) async throws -> DayOneImportPlan {
        try await withThrowingTaskGroup(of: DayOneImportPlan.self) { group in
            group.addTask(priority: .userInitiated) { try prepareImport(from: sourceURL) }
            guard let plan = try await group.next() else { throw CancellationError() }
            if Task.isCancelled {
                deleteTemporaryArchive(plan)
                throw CancellationError()
            }
            return plan
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
            var existingEntries = try existingEntriesBySourceID(in: context)
            progress(DayOneImportProgress(processedEntries: 0, totalEntries: plan.entryCount))

            let scopedArchives = documents.map { document -> [String: Entry] in
                let prefix = document.directory.isEmpty ? "" : normalizePath(document.directory) + "/"
                return prefix.isEmpty ? archiveEntries : archiveEntries.reduce(into: [:]) { result, pair in
                    if pair.key.hasPrefix(prefix) { result[String(pair.key.dropFirst(prefix.count))] = pair.value }
                }
            }
            let records = documents.enumerated().flatMap { index, document in document.entries.map { ($0, index) } }
            for (entryIndex, record) in records.enumerated() {
                let (rawEntry, documentIndex) = record
                let scopedEntries = scopedArchives[documentIndex]
                if Task.isCancelled {
                    summary.wasCancelled = true
                    break
                }

                await importEntry(
                    rawEntry,
                    archive: archive,
                    archiveEntries: scopedEntries,
                    entryNumber: entryIndex + 1,
                    existingEntries: &existingEntries,
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
        } catch is CancellationError {
            summary.wasCancelled = true
        } catch {
            summary.failedEntries += max(1, plan.entryCount - summary.processedEntries)
            summary.issues.append(DayOneImportIssue(sourceID: nil, entryNumber: 0, entryDate: nil, reason: .archiveFailed))
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
            unsupportedMediaCount: entries.reduce(0) { $0 + unsupportedMediaCount(in: $1) },
            ignoredMetadataCount: entries.reduce(0) { $0 + ignoredMetadataCount(in: $1) }
        )
    }

    @MainActor
    private func importEntry(
        _ rawEntry: JSONObject,
        archive: Archive,
        archiveEntries: [String: Entry],
        entryNumber: Int,
        existingEntries: inout [String: JournalEntry],
        context: ModelContext,
        summary: inout DayOneImportSummary
    ) async {
        let sourceID = trimmedString(rawEntry["uuid"])
        func issue(_ reason: DayOneImportIssue.Reason) -> DayOneImportIssue {
            DayOneImportIssue(sourceID: sourceID, entryNumber: entryNumber,
                              entryDate: dateValue(rawEntry["creationDate"]), reason: reason)
        }
        guard let sourceID else {
            summary.failedEntries += 1
            summary.issues.append(issue(.missingIdentity))
            return
        }
        if let existing = existingEntries[sourceID] {
            guard let recoveryData = existing.dayOnePendingPhotos else {
                summary.skippedDuplicates += 1
                return
            }
            await recoverPhotos(in: existing, data: recoveryData, rawEntry: rawEntry,
                                archive: archive, archiveEntries: archiveEntries,
                                context: context, summary: &summary, issue: issue)
            return
        }

        summary.skippedMedia += unsupportedMediaCount(in: rawEntry)
        summary.ignoredMetadata += ignoredMetadataCount(in: rawEntry)
        guard dateValue(rawEntry["creationDate"]) != nil else {
            summary.failedEntries += 1
            summary.issues.append(issue(.invalidDate))
            return
        }
        var copiedFileNames: [String] = []
        do {
            let result = try await buildEntryDataOffMain(from: rawEntry, sourceID: sourceID,
                                                        archive: archive, archiveEntries: archiveEntries)
            copiedFileNames = result.copiedFileNames
            let entry = try makeEntry(from: result.entry, in: context)
            context.insert(entry)
            try saveContext(context)
            existingEntries[sourceID] = entry
            summary.importedEntries += 1
            summary.failedPhotos += result.skippedMedia
            if result.skippedMedia > 0 { summary.issues.append(issue(.photosUnavailable)) }
        } catch let error as DayOneEntryBuildError {
            summary.failedEntries += 1
            summary.failedPhotos += error.skippedMedia
            summary.issues.append(issue(.noContent))
            deleteCopiedPhotos(error.copiedFileNames)
        } catch {
            context.rollback()
            summary.failedEntries += 1
            summary.issues.append(issue(.saveFailed))
            deleteCopiedPhotos(copiedFileNames)
        }
    }

    @MainActor
    private func recoverPhotos(
        in entry: JournalEntry, data: Data, rawEntry: JSONObject,
        archive: Archive, archiveEntries: [String: Entry], context: ModelContext,
        summary: inout DayOneImportSummary,
        issue: (DayOneImportIssue.Reason) -> DayOneImportIssue
    ) async {
        guard let pending = try? JSONDecoder().decode([DayOnePendingPhoto].self, from: data) else {
            summary.failedEntries += 1
            summary.issues.append(issue(.recoveryUnavailable))
            return
        }
        let photos = dayOnePhotos(in: rawEntry)
        var remaining: [DayOnePendingPhoto] = []
        var copied: [String] = []
        var appended = false
        do {
            for (index, record) in pending.enumerated() {
                if Task.isCancelled {
                    remaining.append(contentsOf: pending[index...])
                    summary.wasCancelled = true
                    break
                }
                guard !record.key.hasPrefix("index:"),
                      let photo = photos.first(where: { $0.recoveryKey == record.key || $0.lookupKeys.contains(record.key) }) else {
                    remaining.append(record)
                    continue
                }
                let item: PhotoGroupItem
                do {
                    item = try await withThrowingTaskGroup(of: PhotoGroupItem.self) { group in
                        group.addTask(priority: .userInitiated) {
                            try importPhoto(photo, archive: archive, archiveEntries: archiveEntries)
                        }
                        guard let value = try await group.next() else { throw CancellationError() }
                        return value
                    }
                } catch {
                    remaining.append(record)
                    continue
                }
                copied.append(item.fileName)
                let block: EntryBlock
                if let existing = entry.blocks.first(where: { $0.id == record.groupID && $0.kind == .photoGroup }) {
                    block = existing
                } else {
                    var ordered = entry.orderedBlocks
                    block = EntryBlock(id: record.groupID, kind: .photoGroup, entry: entry)
                    if let anchor = record.beforeBlockID, let position = ordered.firstIndex(where: { $0.id == anchor }) {
                        ordered.insert(block, at: position)
                    } else {
                        ordered.append(block)
                        appended = appended || record.beforeBlockID != nil
                    }
                    for (position, element) in ordered.enumerated() { element.sortIndex = position }
                    entry.blocks.append(block)
                    context.insert(block)
                }
                var orderedPhotos = block.orderedPhotos
                let position = record.followingPhotoIDs.compactMap { id in orderedPhotos.firstIndex { $0.id == id } }.first ?? orderedPhotos.count
                let newPhoto = makePhoto(item, order: position, block: block)
                newPhoto.id = record.photoID
                orderedPhotos.insert(newPhoto, at: position)
                for (position, element) in orderedPhotos.enumerated() { element.displayOrder = position }
                block.photos.append(newPhoto)
                context.insert(newPhoto)
            }
            entry.dayOnePendingPhotos = remaining.isEmpty ? nil : try JSONEncoder().encode(remaining)
            try saveContext(context)
            summary.recoveredPhotos += copied.count
            summary.failedPhotos += remaining.count
            if !copied.isEmpty { summary.repairedEntries += 1 }
            else if !summary.wasCancelled { summary.failedEntries += 1 }
            if !remaining.isEmpty && !summary.wasCancelled { summary.issues.append(issue(.photosUnavailable)) }
            if appended { summary.issues.append(issue(.appendedPhotos)) }
        } catch {
            context.rollback()
            deleteCopiedPhotos(copied)
            summary.failedEntries += 1
            summary.issues.append(issue(.saveFailed))
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
        let content = entryContent(in: rawEntry)
        let photos = dayOnePhotos(in: rawEntry)
        let blockResult = try importedBlocks(
            text: content.body,
            photos: photos,
            unsupportedKeys: unsupportedPhotoReferenceKeys(in: rawEntry),
            archive: archive,
            archiveEntries: archiveEntries
        )

        guard blockResult.blocks.contains(where: \.hasContent) || !content.title.isEmpty else {
            throw DayOneEntryBuildError(
                skippedMedia: blockResult.skippedMedia,
                copiedFileNames: blockResult.copiedFileNames
            )
        }

        let modifiedDate = dateValue(rawEntry["modifiedDate"]) ?? creationDate
        let allDay = allDayValue(rawEntry, creationDate: creationDate)
        let entry = DayOneEntryData(
            externalSourceID: sourceID,
            title: content.title,
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
            skippedMedia: blockResult.skippedMedia,
            copiedFileNames: blockResult.copiedFileNames
        )
    }

    @MainActor
    private func makePhoto(_ photo: PhotoGroupItem, order: Int, block: EntryBlock) -> EntryPhoto {
        EntryPhoto(fileName: photo.fileName, displayOrder: order, capturedAt: photo.capturedAt,
                   placeName: photo.placeName, locationLatitude: photo.locationLatitude,
                   locationLongitude: photo.locationLongitude, block: block)
    }

    @MainActor
    private func makeEntry(from data: DayOneEntryData, in context: ModelContext) throws -> JournalEntry {
        let entry = JournalEntry(externalSourceID: data.externalSourceID, title: data.title,
                                 entryDate: data.entryDate, isAllDay: data.isAllDay,
                                 createdAt: data.createdAt, updatedAt: data.updatedAt,
                                 locationName: data.locationName, locationLatitude: data.locationLatitude,
                                 locationLongitude: data.locationLongitude)
        let blockIDs = data.blocks.map { _ in UUID() }
        var pending: [DayOnePendingPhoto] = []
        for (index, block) in data.blocks.enumerated() {
            switch block {
            case .text(let text):
                let model = EntryBlock(id: blockIDs[index], kind: .text, sortIndex: index, text: text, entry: entry)
                entry.blocks.append(model)
                context.insert(model)
            case .photoGroup(let photos):
                let model = EntryBlock(id: blockIDs[index], kind: .photoGroup, sortIndex: index, entry: entry)
                let photoIDs = photos.map { _ in UUID() }
                let models = photos.enumerated().map { order, photo in
                    photo.item.map { item in
                        let modelPhoto = makePhoto(item, order: order, block: model)
                        modelPhoto.id = photoIDs[order]
                        return modelPhoto
                    }
                }
                for (position, photo) in photos.enumerated() where photo.item == nil {
                    pending.append(DayOnePendingPhoto(key: photo.key, groupID: model.id,
                        photoID: photoIDs[position], followingPhotoIDs: Array(photoIDs.dropFirst(position + 1)),
                        beforeBlockID: blockIDs.dropFirst(index + 1).first))
                }
                model.photos = models.compactMap { $0 }
                if !model.photos.isEmpty {
                    entry.blocks.append(model)
                    context.insert(model)
                    model.photos.forEach { context.insert($0) }
                }
            }
        }
        // Keep text anchors distinct while photos are missing. Editor normalization may
        // later remove an anchor; recovery then appends instead of rewriting user text.
        if pending.isEmpty { entry.normalizeBlocks(in: context) }
        entry.dayOnePendingPhotos = pending.isEmpty ? nil : try JSONEncoder().encode(pending)
        return entry
    }

    private func importedBlocks(
        text: String,
        photos: [DayOnePhoto],
        unsupportedKeys: Set<String>,
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
        var unresolvedKeys = Set<String>()
        var pendingPhotos: [ImportedPhoto] = []
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
            let value = plainText(trimBoundaryLines(nsText.substring(with: range)))
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

            let tokenRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let key = nsText.substring(with: tokenRange).lowercased()
            if unsupportedKeys.contains(key) { continue }
            guard let photoIndex = photosByKey[key] else {
                if unresolvedKeys.insert(key).inserted {
                    pendingPhotos.append(ImportedPhoto(key: key, item: nil))
                    skippedMedia += 1
                }
                continue
            }
            guard !usedPhotoIndexes.contains(photoIndex) else { continue }

            usedPhotoIndexes.insert(photoIndex)
            do {
                let item = try importPhoto(photos[photoIndex], archive: archive, archiveEntries: archiveEntries)
                pendingPhotos.append(ImportedPhoto(key: photos[photoIndex].recoveryKey, item: item))
                copiedFileNames.append(item.fileName)
            } catch {
                pendingPhotos.append(ImportedPhoto(key: photos[photoIndex].recoveryKey, item: nil))
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
            blocks.append(.text(plainText(trimBoundaryLines(text))))
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
    ) throws -> (photos: [ImportedPhoto], skippedMedia: Int, copiedFileNames: [String]) {
        var importedPhotos: [ImportedPhoto] = []
        var skippedMedia = 0
        var copiedFileNames: [String] = []

        for photo in photos {
            do {
                let item = try importPhoto(photo, archive: archive, archiveEntries: archiveEntries)
                importedPhotos.append(ImportedPhoto(key: photo.recoveryKey, item: item))
                copiedFileNames.append(item.fileName)
            } catch {
                importedPhotos.append(ImportedPhoto(key: photo.recoveryKey, item: nil))
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
        let matches = entries.filter { path, _ in
            guard path.contains("photos/") else { return false }
            let lastComponent = (path as NSString).lastPathComponent
            let stem = ((lastComponent as NSString).deletingPathExtension).lowercased()
            return lookupKeys.contains(stem)
        }
        return matches.count == 1 ? matches.first?.value : nil
    }

    private func dayOneDocuments(in archive: Archive) throws -> [DayOneDocument] {
        var documents: [DayOneDocument] = []

        for entry in archive {
            try Task.checkCancellation()
            guard entry.type == .file,
                  entry.path.lowercased().hasSuffix(".json") else { continue }

            let data = try extractChecked(entry, from: archive)

            guard let root = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
                  let values = root["entries"] as? [Any] else { continue }
            let entries = values.map { $0 as? JSONObject ?? [:] }

            documents.append(DayOneDocument(entries: entries, directory: (entry.path as NSString).deletingLastPathComponent))
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
    private func existingEntriesBySourceID(in context: ModelContext) throws -> [String: JournalEntry] {
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        return entries.reduce(into: [:]) { result, entry in
            if let key = trimmedString(entry.externalSourceID), result[key] == nil { result[key] = entry }
        }
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

    private func unsupportedPhotoReferenceKeys(in rawEntry: JSONObject) -> Set<String> {
        let keys = ["videos", "audios", "audio", "pdfs", "attachments", "files"]
        return Set(keys.flatMap { rawEntry[$0] as? [JSONObject] ?? [] }
            .flatMap { [trimmedString($0["identifier"]), trimmedString($0["md5"])] }
            .compactMap { $0?.lowercased() })
    }

    private func unsupportedMediaCount(in rawEntry: JSONObject) -> Int {
        let arrayKeys = ["videos", "audios", "audio", "pdfs", "attachments", "files"]
        let arrayCount = arrayKeys.reduce(0) { count, key in
            count + ((rawEntry[key] as? [Any])?.count ?? 0)
        }
        return arrayCount
    }

    private func ignoredMetadataCount(in rawEntry: JSONObject) -> Int {
        let metadataKeys = ["weather", "music", "activity", "userActivity", "steps", "starred", "isPinned"]
        let metadataCount = metadataKeys.reduce(0) { count, key in
            count + (rawEntry[key] == nil ? 0 : 1)
        }
        let tagCount = (rawEntry["tags"] as? [Any])?.count ?? 0
        return metadataCount + tagCount
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

    /// Strip empty boundary lines, never indentation or spaces inside a paragraph/code block.
    private func trimBoundaryLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")[...]
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func entryContent(in rawEntry: JSONObject) -> (title: String, body: String) {
        let body = sourceText(in: rawEntry).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let explicitTitle = trimmedString(rawEntry["title"]) ?? ""
        guard explicitTitle.isEmpty else { return (explicitTitle, body) }
        let trimmed = trimBoundaryLines(body)
        let lines = trimmed.components(separatedBy: "\n")
        guard let first = lines.first,
              first.range(of: #"^ {0,3}#\s+\S"#, options: .regularExpression) != nil,
              Self.momentRegex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) == nil else {
            return ("", body)
        }
        let heading = first.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        return (plainText(heading).trimmingCharacters(in: .whitespaces),
                trimBoundaryLines(lines.dropFirst().joined(separator: "\n")))
    }

    private func sourceText(in rawEntry: JSONObject) -> String {
        if let text = stringValue(rawEntry["text"]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        let rich: JSONObject?
        if let encoded = stringValue(rawEntry["richText"]), let data = encoded.data(using: .utf8) {
            rich = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
        } else {
            rich = rawEntry["richText"] as? JSONObject
        }
        guard let contents = rich?["contents"] as? [JSONObject] else { return "" }
        var text = ""
        for content in contents {
            if let value = content["text"] as? String {
                let line = (content["attributes"] as? JSONObject)?["line"] as? JSONObject
                if let header = line?["header"] as? Int, (1...6).contains(header) {
                    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                    text += String(repeating: "#", count: header) + " "
                }
                let indent = String(repeating: "  ", count: min(20, max(0, (line?["indentLevel"] as? Int ?? 1) - 1)))
                switch line?["listStyle"] as? String {
                case "bulleted": text += indent + "• "
                case "checkbox": text += indent + (boolValue(line?["checked"]) == true ? "☑ " : "☐ ")
                case "numbered": text += indent + "1. "
                default: break
                }
                // Escape literal syntax so the Markdown fallback does not reinterpret rich text.
                for character in value {
                    if "\\`*_{}[]()#+-.!>|~".contains(character) { text += "\\" }
                    text.append(character)
                }
            }
            for object in content["embeddedObjects"] as? [JSONObject] ?? [] {
                switch object["type"] as? String {
                case "photo":
                    if let key = trimmedString(object["identifier"]) { text += "\ndayone-moment://\(key)\n" }
                case "horizontalRuleLine": text += "\n———\n"
                default: break
                }
            }
        }
        return text
    }

    private func plainText(_ markdown: String) -> String {
        var inCode = false
        return markdown.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                return ""
            }
            if inCode { return line }
            if line.range(of: #"^ {0,3}([-*_])(?:\s*\1){2,}\s*$"#, options: .regularExpression) != nil {
                return "———"
            }
            let readable = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)[-*+] \[[xX]\] "#, with: "$1☑ ", options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)[-*+] \[ \] "#, with: "$1☐ ", options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)[-*+] "#, with: "$1• ", options: .regularExpression)
            guard let attributed = try? AttributedString(markdown: readable,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return readable }
            var result = ""
            var activeLink: URL?
            var linkText = ""
            func finishLink() {
                if let url = activeLink, linkText != url.absoluteString { result += " (\(url.absoluteString))" }
                activeLink = nil
                linkText = ""
            }
            for run in attributed.runs {
                if activeLink != run.link { finishLink(); activeLink = run.link }
                let value = String(attributed[run.range].characters)
                result += value
                if activeLink != nil { linkText += value }
            }
            finishLink()
            return result
        }.joined(separator: "\n")
    }

    private static let momentRegex = try! NSRegularExpression(
        pattern: #"!\[[^\]\n]*\]\(dayone-moment://([A-Za-z0-9_-]+)\)|dayone-moment://([A-Za-z0-9_-]+)"#
    )

    private typealias JSONObject = [String: Any]

    private struct DayOneDocument {
        let entries: [JSONObject]
        let directory: String
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

        var recoveryKey: String {
            identifier?.lowercased() ?? md5?.lowercased() ?? fileName?.lowercased() ?? "index:\(index)"
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

    private struct ImportedPhoto {
        let key: String
        let item: PhotoGroupItem?
    }

    private enum ImportedEntryBlock {
        case text(String)
        case photoGroup([ImportedPhoto])

        var hasContent: Bool {
            switch self {
            case .text(let text):
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .photoGroup(let photos):
                photos.contains { $0.item != nil }
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
