import SwiftData
import Testing
import UIKit
import ZIPFoundation
@testable import Liney

private let entryCount = 150
private let photosPerEntry = 3
private let baseDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

private struct SyntheticFailure: Error { }

/// Counts calls, including the import's background photo copies, so a fixture can fail the nth one.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// A file system whose temporary directory can be a fixture folder.
private class TemporaryRootFileManager: FileManager, @unchecked Sendable {
    private let root: URL?

    init(temporaryRoot root: URL? = nil) {
        self.root = root
        super.init()
    }

    override var temporaryDirectory: URL { root ?? super.temporaryDirectory }
}

/// A file system where nothing can be deleted, as when a file is locked or permissions changed.
private final class UndeletableFileManager: TemporaryRootFileManager, @unchecked Sendable {
    override func removeItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private struct ApprovingAuthenticator: AppAuthenticating {
    func authenticate(reason: String) async -> Bool { true }
}

/// Interrupted Day One import and Markdown export on a media-heavy synthetic journal (#3).
@Suite(.serialized)
@MainActor
final class InterruptedTransferTests {
    private let container: ModelContainer
    private let directory: URL
    private let storage: PhotoStorage

    init() throws {
        container = try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = PhotoStorage(baseURL: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    // MARK: - Import

    enum Interruption: CaseIterable { case cancel, saveFailure, photoFailure }

    /// The 1-based entry number at which the import is interrupted.
    enum Point: Int, CaseIterable { case early = 5, middle = 75, late = 145 }

    @Test(arguments: Interruption.allCases, Point.allCases)
    func `interrupted import leaves a consistent journal that a re-import completes`(
        interruption: Interruption, point: Point
    ) async throws {
        let archiveURL = try makeArchive()
        let context = ModelContext(container)
        let failingEntry = point.rawValue
        let calls = CallCounter()
        let photoStorage = interruption == .photoFailure ? photoStorageFailing(entry: failingEntry) : storage
        let importer = DayOneImporter(photoStorage: photoStorage, saveContext: { context in
            if interruption == .saveFailure, calls.next() == failingEntry { throw SyntheticFailure() }
            try context.save()
        })

        let first = await importer.importPreparedArchive(try importer.prepareImport(from: archiveURL), into: context) { progress in
            if interruption == .cancel, progress.processedEntries == failingEntry { withUnsafeCurrentTask { $0?.cancel() } }
        }

        let sourceID = "synthetic-\(failingEntry)"
        switch interruption {
        case .cancel:
            expectSummary(first, DayOneImportSummary(importedEntries: failingEntry, processedEntries: failingEntry,
                                                     totalEntries: entryCount, wasCancelled: true))
            #expect(try journal() == expectedJournal(1...failingEntry))
        case .saveFailure:
            expectSummary(first, DayOneImportSummary(importedEntries: entryCount - 1, failedEntries: 1, processedEntries: entryCount,
                                                     totalEntries: entryCount), issues: ["\(failingEntry)|\(sourceID)|saveFailed"])
            #expect(try journal() == expectedJournal((1...entryCount).filter { $0 != failingEntry }))
        case .photoFailure:
            expectSummary(first, DayOneImportSummary(importedEntries: entryCount, processedEntries: entryCount, totalEntries: entryCount,
                                                     failedPhotos: photosPerEntry), issues: ["\(failingEntry)|\(sourceID)|photosUnavailable"])
            var expected = expectedJournal(1...entryCount)
            expected[sourceID] = textOnly(failingEntry)
            #expect(try journal() == expected)
            let pending = try #require(try context.fetch(FetchDescriptor<JournalEntry>()).first { $0.externalSourceID == sourceID })
            #expect(pending.dayOnePendingPhotos != nil)
        }
        #expect(try unreferencedPhotoFiles(in: context).isEmpty)

        let retryImporter = DayOneImporter(photoStorage: storage)
        let retry = await retryImporter.importPreparedArchive(try retryImporter.prepareImport(from: archiveURL), into: context) { _ in }

        switch interruption {
        case .cancel:
            expectSummary(retry, DayOneImportSummary(importedEntries: entryCount - failingEntry, skippedDuplicates: failingEntry,
                                                     processedEntries: entryCount, totalEntries: entryCount))
        case .saveFailure:
            expectSummary(retry, DayOneImportSummary(importedEntries: 1, skippedDuplicates: entryCount - 1,
                                                     processedEntries: entryCount, totalEntries: entryCount))
        case .photoFailure:
            expectSummary(retry, DayOneImportSummary(skippedDuplicates: entryCount - 1, processedEntries: entryCount,
                                                     totalEntries: entryCount, repairedEntries: 1, recoveredPhotos: photosPerEntry))
        }
        #expect(try journal() == expectedJournal(1...entryCount))
        #expect(try timelineOrder() == (1...entryCount).reversed().map { "synthetic-\($0)" })
        #expect(try photoFiles().count == entryCount * photosPerEntry)
        #expect(try unreferencedPhotoFiles(in: context).isEmpty)
    }

    /// Where the import deletes photos it copied: after a new entry fails to save, or after a recovery fails to save.
    enum CleanupPath: CaseIterable { case newEntry, recovery }

    @Test(arguments: CleanupPath.allCases)
    func `import tells the user when copied photos cannot be deleted and keeps the journal`(path: CleanupPath) async throws {
        let seed = try seedSavedEntry()
        let archiveURL = try makeArchive()
        let context = ModelContext(container)
        let failingEntry = Point.middle.rawValue
        let sourceID = "synthetic-\(failingEntry)"
        if path == .recovery {
            let partial = DayOneImporter(photoStorage: photoStorageFailing(entry: failingEntry))
            _ = await partial.importPreparedArchive(try partial.prepareImport(from: archiveURL), into: context) { _ in }
        }
        let before = try journal()
        let calls = CallCounter()
        let importer = DayOneImporter(photoStorage: PhotoStorage(fileManager: UndeletableFileManager(), baseURL: directory),
                                      saveContext: { context in
            // Recovery saves only the entry it repairs; a new import saves every entry.
            if path == .recovery || calls.next() == failingEntry { throw SyntheticFailure() }
            try context.save()
        })

        let summary = await importer.importPreparedArchive(try importer.prepareImport(from: archiveURL), into: context) { _ in }

        let issues = ["\(failingEntry)|\(sourceID)|saveFailed", "\(failingEntry)|\(sourceID)|cleanupFailed"]
        switch path {
        case .newEntry:
            expectSummary(summary, DayOneImportSummary(importedEntries: entryCount - 1, failedEntries: 1, processedEntries: entryCount,
                                                       totalEntries: entryCount), issues: issues)
            #expect(try journal()[sourceID] == nil)
        case .recovery:
            expectSummary(summary, DayOneImportSummary(skippedDuplicates: entryCount - 1, failedEntries: 1, processedEntries: entryCount,
                                                       totalEntries: entryCount), issues: issues)
            #expect(try journal() == before)
        }
        #expect(ImportJournalViewController.summaryRows(summary).contains {
            $0.hasSuffix(String(localized: "Some copied photo files could not be deleted."))
        })
        #expect(try seedSnapshot(seed.id) == seed.snapshot)
        // These are the orphans reported in #3: the failed entry's copies that could not be deleted.
        #expect(try unreferencedPhotoFiles(in: context).count == photosPerEntry)
    }

    @Test(.bug("https://github.com/pumblus/liney/issues/3"))
    func `photo copies whose deletion failed are gone after a later successful import`() async throws {
        let archiveURL = try makeArchive()
        let context = ModelContext(container)
        let calls = CallCounter()
        let failing = DayOneImporter(photoStorage: PhotoStorage(fileManager: UndeletableFileManager(), baseURL: directory),
                                     saveContext: { context in
            if calls.next() == Point.middle.rawValue { throw SyntheticFailure() }
            try context.save()
        })
        _ = await failing.importPreparedArchive(try failing.prepareImport(from: archiveURL), into: context) { _ in }
        let retryImporter = DayOneImporter(photoStorage: storage)
        let retry = await retryImporter.importPreparedArchive(try retryImporter.prepareImport(from: archiveURL), into: context) { _ in }
        #expect(retry.importedEntries == 1)
        #expect(try journal() == expectedJournal(1...entryCount))

        let orphans = try unreferencedPhotoFiles(in: context)
        withKnownIssue("Nothing sweeps photo copies whose deletion failed; orphan cleanup needs a separately authorized plan") {
            #expect(orphans.isEmpty)
        }
    }

    @Test(.bug("https://github.com/pumblus/liney/issues/3"))
    func `staged import archive does not outlive a failed deletion`() async throws {
        let archiveURL = try makeArchive()
        let stagingRoot = directory.appendingPathComponent("Temporary", isDirectory: true)
        let importer = DayOneImporter(fileManager: UndeletableFileManager(temporaryRoot: stagingRoot), photoStorage: storage)

        let summary = await importer.importPreparedArchive(try importer.prepareImport(from: archiveURL),
                                                           into: ModelContext(container)) { _ in }

        #expect(summary.importedEntries == entryCount)
        #expect(try journal() == expectedJournal(1...entryCount))
        let staged = stagingRoot.appendingPathComponent("LineyImports", isDirectory: true)
        // The staged copy stays until the next launch sweeps it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: staged.path).count == 1)
        let exports = stagingRoot.appendingPathComponent("LineyExports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        let launch = DayOneImporter(fileManager: TemporaryRootFileManager(temporaryRoot: stagingRoot), photoStorage: storage)
        launch.deleteTemporaryImports()
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(FileManager.default.fileExists(atPath: exports.path))
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))

        // A launch with nothing staged is a no-op.
        launch.deleteTemporaryImports()
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
    // MARK: - Export

    @Test
    func `media-heavy export writes every entry and photo`() async throws {
        try await seedJournal()
        let exporter = JournalExporter(photoStorage: storage, exportRootURL: exportRoot)

        let export = try exporter.export(entries: try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()))
        defer { exporter.deleteExport(export) }

        let paths = try Archive(url: export.url, accessMode: .read, pathEncoding: nil).map(\.path)
        #expect(paths.filter { $0.hasSuffix(".md") }.count == entryCount)
        #expect(paths.filter { $0.hasSuffix(".jpg") }.count == entryCount * photosPerEntry)
    }

    /// Each entry writes its photos, then its Markdown: 600 writes in all.
    @Test(arguments: [5, entryCount * (photosPerEntry + 1) / 2, entryCount * (photosPerEntry + 1)])
    func `export failing mid-write leaves no partial output`(failingWrite: Int) async throws {
        try await seedJournal()
        let before = try journal()
        let calls = CallCounter()
        let exporter = JournalExporter(photoStorage: storage, exportRootURL: exportRoot) { archive, path, data in
            if calls.next() == failingWrite { throw SyntheticFailure() }
            try Self.write(data, path: path, to: archive)
        }

        #expect(throws: SyntheticFailure.self) {
            try exporter.export(entries: try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()))
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: exportRoot.path).isEmpty)
        #expect(try journal() == before)
    }

    @Test
    func `export that cannot remove its partial archive shows the export alert and sweeps it at next launch`() async throws {
        try await seedJournal()
        let before = try journal()
        let photosBefore = try photoFileContents()
        let calls = CallCounter()
        let exporter = JournalExporter(fileManager: UndeletableFileManager(), photoStorage: storage,
                                       exportRootURL: exportRoot) { archive, path, data in
            if calls.next() == entryCount * (photosPerEntry + 1) / 2 { throw SyntheticFailure() }
            try Self.write(data, path: path, to: archive)
        }
        let presenter = UIViewController()
        let window = try show(presenter)
        defer { window.isHidden = true }
        let flow = ExportJournalFlow(presenter: presenter, container: container,
                                     appLock: AppLockModel(authenticator: ApprovingAuthenticator()), exporter: exporter)

        flow.start()

        let alert = try await waitForAlert(from: presenter)
        #expect(alert.title == String(localized: "Could Not Export Journal"))
        #expect(alert.message == String(localized: "The journal could not be exported. Please try again."))
        #expect(try journal() == before)
        #expect(try photoFileContents() == photosBefore)
        // The partial archive stays in the app's temporary exports, which are not shared or shown in Files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: exportRoot.path).count == 1)

        JournalExporter(exportRootURL: exportRoot).deleteTemporaryExports()
        #expect(!FileManager.default.fileExists(atPath: exportRoot.path))
    }

    // MARK: - Fixtures

    private var exportRoot: URL { directory.appendingPathComponent("Exports", isDirectory: true) }

    /// Entry n has text, photo a, more text, then photos b and c in one group.
    private func makeArchive() throws -> URL {
        let url = directory.appendingPathComponent("synthetic-day-one.zip")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        let formatter = ISO8601DateFormatter()
        let entries: [[String: Any]] = (1...entryCount).map { n in
            [
                "uuid": "synthetic-\(n)",
                "creationDate": formatter.string(from: entryDate(n)),
                "text": "Synthetic body \(n) before\n\n![](dayone-moment://p\(n)a)\n\nSynthetic body \(n) after\n\n" +
                    "![](dayone-moment://p\(n)b)\n![](dayone-moment://p\(n)c)",
                "photos": ["a", "b", "c"].enumerated().map { offset, suffix in
                    ["identifier": "p\(n)\(suffix)", "type": "jpeg",
                     "date": formatter.string(from: photoDate(n, offset))]
                }
            ]
        }
        try Self.write(try JSONSerialization.data(withJSONObject: ["entries": entries]), path: "Journal.json", to: archive)
        let jpeg = jpegData()
        for n in 1...entryCount {
            for suffix in ["a", "b", "c"] {
                try Self.write(jpeg, path: "photos/p\(n)\(suffix).jpeg", to: archive)
            }
        }
        return url
    }

    private func entryDate(_ n: Int) -> Date { baseDate.addingTimeInterval(Double(n) * 3600) }

    private func photoDate(_ n: Int, _ offset: Int) -> Date { entryDate(n).addingTimeInterval(Double(offset + 1) * 60) }

    private func seedJournal() async throws {
        let importer = DayOneImporter(photoStorage: storage)
        let summary = await importer.importPreparedArchive(try importer.prepareImport(from: makeArchive()),
                                                           into: ModelContext(container)) { _ in }
        try #require(summary.importedEntries == entryCount)
    }

    /// Each imported entry as its ordered blocks; photos are identified by their source capture date.
    private func journal() throws -> [String: [String]] {
        try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).reduce(into: [:]) { result, entry in
            result[entry.externalSourceID ?? entry.id.uuidString] = entry.orderedBlocks.map { block in
                switch block.kind {
                case .text: "text:\(block.text)"
                case .photoGroup: "photos:" + block.orderedPhotos.map { "\(Int($0.capturedAt?.timeIntervalSince1970 ?? 0))" }
                    .joined(separator: ",")
                }
            }
        }
    }

    private func expectedJournal(_ numbers: some Sequence<Int>) -> [String: [String]] {
        numbers.reduce(into: [:]) { result, n in
            let stamp = { (offset: Int) in "\(Int(self.photoDate(n, offset).timeIntervalSince1970))" }
            result["synthetic-\(n)"] = ["text:Synthetic body \(n) before", "photos:\(stamp(0))",
                                        "text:Synthetic body \(n) after", "photos:\(stamp(1)),\(stamp(2))"]
        }
    }

    private func textOnly(_ n: Int) -> [String] {
        ["text:Synthetic body \(n) before", "text:Synthetic body \(n) after"]
    }

    /// Photo storage whose writes fail for every photo of one entry; photos are copied in archive order.
    private func photoStorageFailing(entry n: Int) -> PhotoStorage {
        let calls = CallCounter()
        let failingWrites = (photosPerEntry * (n - 1) + 1)...(photosPerEntry * n)
        return PhotoStorage(baseURL: directory) { data, url in
            if failingWrites.contains(calls.next()) { throw SyntheticFailure() }
            try data.write(to: url, options: .atomic)
        }
    }

    /// Source IDs in the timeline's newest-first order.
    private func timelineOrder() throws -> [String?] {
        try ModelContext(container).fetch(FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.entryDate, order: .reverse)]))
            .map(\.externalSourceID)
    }

    private func expectSummary(_ summary: DayOneImportSummary, _ expected: DayOneImportSummary, issues: [String] = [],
                               sourceLocation: SourceLocation = #_sourceLocation) {
        var counts = summary
        counts.issues = []
        #expect(counts == expected, sourceLocation: sourceLocation)
        #expect(summary.issues.map { "\($0.entryNumber)|\($0.sourceID ?? "")|\($0.reason)" } == issues,
                sourceLocation: sourceLocation)
    }

    private func photoFiles() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: storage.photoDirectoryURL.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: storage.photoDirectoryURL.path))
    }

    private func photoFileContents() throws -> [String: Data] {
        try photoFiles().reduce(into: [:]) { $0[$1] = try Data(contentsOf: storage.url(for: $1)) }
    }

    private func unreferencedPhotoFiles(in context: ModelContext) throws -> Set<String> {
        try photoFiles().subtracting(context.fetch(FetchDescriptor<EntryPhoto>()).map(\.fileName))
    }

    private func seedSavedEntry() throws -> (id: UUID, snapshot: String) {
        let context = ModelContext(container)
        let entry = JournalEntry(title: "Synthetic saved title")
        context.insert(entry)
        _ = entry.insertTextBlock("Synthetic saved body", in: context)
        let photo = try #require(storage.saveJPEGs(from: [jpegData()]).photos.first)
        _ = entry.insertPhotoGroup(photos: [photo], in: context)
        try context.save()
        return (entry.id, try #require(try seedSnapshot(entry.id)))
    }

    private func seedSnapshot(_ id: UUID) throws -> String? {
        guard let entry = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).first(where: { $0.id == id }) else {
            return nil
        }
        let photos = try entry.orderedBlocks.flatMap(\.orderedPhotos).map {
            "\($0.fileName):\(try Data(contentsOf: storage.url(for: $0.fileName)).count)"
        }
        return "\(entry.title)|\(entry.plainTextBody)|\(photos.joined(separator: ","))"
    }

    private nonisolated static func write(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    private func jpegData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
    }

    private func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    private func waitForAlert(from controller: UIViewController) async throws -> UIAlertController {
        for _ in 0..<500 {
            if let alert = presentedAlert(from: controller) { return alert }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(presentedAlert(from: controller))
    }

    private func presentedAlert(from controller: UIViewController) -> UIAlertController? {
        var presented = controller.navigationController?.presentedViewController ?? controller.presentedViewController
        while let current = presented {
            if let alert = current as? UIAlertController { return alert }
            presented = current.presentedViewController
        }
        return nil
    }
}
