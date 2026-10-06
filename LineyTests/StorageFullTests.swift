import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation
@testable import Liney

/// The error Foundation reports when a write runs out of space. Its path would show up in an
/// alert that leaked raw error text.
private func outOfSpaceError() -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [
        NSFilePathErrorKey: "/fixture/private-path.jpg",
        NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    ])
}

private let storageFullMessage = String(localized: "There isn’t enough storage on this device. Free up space and try again.")

private final class FullDisk {
    var isFull = true
}

/// Keeps import staging inside the fixture directory; a failing copy leaves a truncated file,
/// as an interrupted copy on a full disk would.
private final class FixtureFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    private let copyFails: Bool

    init(root: URL, copyFails: Bool) {
        self.root = root
        self.copyFails = copyFails
        super.init()
    }

    override var temporaryDirectory: URL { root }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        guard copyFails else { return try super.copyItem(at: srcURL, to: dstURL) }
        try Data(contentsOf: srcURL).prefix(16).write(to: dstURL)
        throw outOfSpaceError()
    }
}

/// Synthetic entries and files as they are on disk, so a failed write can be shown to change nothing.
private struct JournalSnapshot: Equatable {
    let entries: [String]
    let files: [String: Data]
}

@Suite(.serialized)
@MainActor
final class StorageFullTests {
    private let container: ModelContainer
    private let directory: URL
    private let storage: PhotoStorage

    init() throws {
        container = try makeInMemoryContainer()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = PhotoStorage(baseURL: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func `entry editor keeps unsaved text and saved data when storage is full`() async throws {
        try seedSavedEntry()
        let before = try snapshot()
        let disk = FullDisk()
        let context = ModelContext(container)
        let entry = try #require(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        let editor = EntryEditorViewController(entry: entry, isNew: false, context: context, storage: storage) {
            if disk.isFull { throw outOfSpaceError() }
            try $0.save()
        }
        let window = try show(editor)
        defer { window.isHidden = true }
        let body = try #require(descendants(editor.view, as: UITextView.self).first { $0.text == "Synthetic saved body" })
        body.text = "Synthetic saved body, unsaved line"
        editor.textViewDidChange(body)

        #expect(!editor.flush())
        let alert = try await waitForAlert(from: editor)
        #expect(alert.title == String(localized: "Could Not Save Entry"))
        #expect(alert.message == storageFullMessage)
        #expect(try snapshot() == before)
        #expect(body.text == "Synthetic saved body, unsaved line")
        #expect(entry.plainTextBody == "Synthetic saved body, unsaved line")

        await dismiss(alert)
        disk.isFull = false
        #expect(editor.flush())
        #expect(try snapshot().entries == ["Synthetic saved title|Synthetic saved body, unsaved line|1"])
    }

    @Test
    func `timeline deletion keeps the entry and its photo when storage is full`() async throws {
        let id = try seedSavedEntry()
        let before = try snapshot()
        let timeline = TimelineViewController(container: container, appLock: AppLockModel(), storage: storage) { _ in
            throw outOfSpaceError()
        }
        let window = try show(timeline)
        defer { window.isHidden = true }

        timeline.deleteEntry(id: id)

        let alert = try await waitForAlert(from: timeline)
        #expect(alert.title == String(localized: "Could Not Save Entry"))
        #expect(alert.message == storageFullMessage)
        #expect(try snapshot() == before)
    }

    enum PhotoFailure: CaseIterable { case copy, save }

    @Test(arguments: PhotoFailure.allCases)
    func `adding photos on a full disk leaves no copied files`(failure: PhotoFailure) async throws {
        try seedSavedEntry()
        let before = try snapshot()
        let photoStorage = failure == .copy ? PhotoStorage(baseURL: directory) { _, _ in throw outOfSpaceError() } : storage
        let context = ModelContext(container)
        let entry = try #require(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        let editor = EntryEditorViewController(entry: entry, isNew: false, context: context, storage: photoStorage) {
            if failure == .save { throw outOfSpaceError() }
            try $0.save()
        }
        let window = try show(editor)
        defer { window.isHidden = true }
        let photos = [jpegData(), jpegData()]

        editor.importPhotos { photoStorage.saveJPEGs(from: photos) }

        let alert = try await waitForAlert(from: editor)
        #expect(alert.title == String(localized: "Some Photos Couldn’t Be Added"))
        #expect(alert.message == storageFullMessage)
        #expect(try snapshot() == before)
        #expect(entry.photoCount == 1)
    }

    @Test
    func `Day One import staging cleans up its partial copy when storage is full`() async throws {
        try seedSavedEntry()
        let archiveURL = try makeDayOneArchive()
        let before = try snapshot()
        let importer = DayOneImporter(fileManager: FixtureFileManager(root: directory, copyFails: true), photoStorage: storage)
        let controller = ImportJournalViewController(container: container, importer: importer)
        let window = try show(controller)
        defer { window.isHidden = true }

        controller.documentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.zip]), didPickDocumentsAt: [archiveURL])

        let alert = try await waitForAlert(from: controller)
        #expect(alert.title == String(localized: "Could Not Import Journal"))
        #expect(alert.message == storageFullMessage)
        #expect(try snapshot() == before)
    }

    @Test
    func `Day One entries that cannot be saved on a full disk leave no photos behind`() async throws {
        try seedSavedEntry()
        let archiveURL = try makeDayOneArchive()
        let before = try snapshot()
        let importer = DayOneImporter(fileManager: FixtureFileManager(root: directory, copyFails: false), photoStorage: storage,
                                      saveContext: { _ in throw outOfSpaceError() })

        let summary = await importer.importPreparedArchive(try importer.prepareImport(from: archiveURL),
                                                           into: ModelContext(container)) { _ in }

        #expect(summary.importedEntries == 0)
        #expect(summary.failedEntries == 1)
        #expect(ImportJournalViewController.summaryRows(summary).contains {
            $0.hasSuffix(String(localized: "This entry could not be saved. Check available storage and retry."))
        })
        #expect(try snapshot() == before)
    }

    @Test
    func `Day One photos that cannot be copied on a full disk can be recovered later`() async throws {
        try seedSavedEntry()
        let archiveURL = try makeDayOneArchive()
        let photosBefore = try snapshot().files.keys.filter { $0.hasPrefix("Photos/") }
        let fileManager = FixtureFileManager(root: directory, copyFails: false)
        let context = ModelContext(container)
        let fullDiskStorage = PhotoStorage(baseURL: directory) { _, _ in throw outOfSpaceError() }

        let first = DayOneImporter(fileManager: fileManager, photoStorage: fullDiskStorage)
        let partial = await first.importPreparedArchive(try first.prepareImport(from: archiveURL), into: context) { _ in }
        #expect(partial.importedEntries == 1)
        #expect(partial.failedPhotos == 1)
        #expect(ImportJournalViewController.summaryRows(partial).contains {
            $0.hasSuffix(String(localized: "Some photos could not be saved because this device is out of storage. Free up space and import the zip again to retry."))
        })

        // Recovery copies the photo, then the save runs out of space; the entry and photos stay as they were.
        let second = DayOneImporter(fileManager: fileManager, photoStorage: storage, saveContext: { _ in throw outOfSpaceError() })
        let failed = await second.importPreparedArchive(try second.prepareImport(from: archiveURL), into: context) { _ in }
        #expect(failed.issues.map(\.reason) == [.saveFailed])
        let imported = try #require(try context.fetch(FetchDescriptor<JournalEntry>()).first { $0.externalSourceID == "synthetic-full-disk" })
        #expect(imported.photoCount == 0)
        #expect(imported.plainTextBody == "Synthetic imported body")
        #expect(try snapshot().files.keys.filter { $0.hasPrefix("Photos/") }.sorted() == photosBefore.sorted())

        let third = DayOneImporter(fileManager: fileManager, photoStorage: storage)
        let recovered = await third.importPreparedArchive(try third.prepareImport(from: archiveURL), into: context) { _ in }
        #expect(recovered.recoveredPhotos == 1)
        #expect(try snapshot().entries.contains("Synthetic saved title|Synthetic saved body|1"))
    }

    @Test
    func `Markdown export removes its partial archive when storage is full`() async throws {
        try seedSavedEntry()
        let before = try snapshot()
        // Photos are written before each entry's Markdown, so the archive is partly written when this fails.
        let exporter = JournalExporter(photoStorage: storage, exportRootURL: directory.appendingPathComponent("Exports", isDirectory: true)) { archive, path, data in
            if path.hasSuffix(".md") { throw POSIXError(.ENOSPC) }
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        let presenter = UIViewController()
        let window = try show(presenter)
        defer { window.isHidden = true }
        let flow = ExportJournalFlow(presenter: presenter, container: container,
                                     appLock: AppLockModel(authenticator: ApprovingAuthenticator()), exporter: exporter)
        var finished = false
        flow.onFinished = { finished = true }

        flow.start()

        let alert = try await waitForAlert(from: presenter)
        #expect(alert.title == String(localized: "Could Not Export Journal"))
        #expect(alert.message == storageFullMessage)
        #expect(finished)
        #expect(try snapshot() == before)
    }

    @Test(arguments: [
        outOfSpaceError() as Error,
        POSIXError(.ENOSPC),
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC) as NSError])
    ])
    func `full-disk errors are recognized however they are wrapped`(error: Error) {
        #expect(writeFailureMessage(for: error, otherwise: "Fallback") == storageFullMessage)
    }

    @Test
    func `other write errors use the fallback instead of raw error text`() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                            userInfo: [NSFilePathErrorKey: "/fixture/private-path.jpg"])
        #expect(writeFailureMessage(for: error, otherwise: "Fallback") == "Fallback")
    }

    // MARK: - Fixtures

    @discardableResult
    private func seedSavedEntry() throws -> UUID {
        let context = ModelContext(container)
        let entry = JournalEntry(title: "Synthetic saved title")
        context.insert(entry)
        _ = entry.insertTextBlock("Synthetic saved body", in: context)
        let photo = try #require(storage.saveJPEGs(from: [jpegData()]).photos.first)
        _ = entry.insertPhotoGroup(photos: [photo], in: context)
        try context.save()
        return entry.id
    }

    private func snapshot() throws -> JournalSnapshot {
        let entries = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).map {
            "\($0.title)|\($0.plainTextBody)|\($0.photoCount)"
        }
        var files: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[path] = try Data(contentsOf: url)
        }
        return JournalSnapshot(entries: entries.sorted(), files: files)
    }

    private func makeDayOneArchive() throws -> URL {
        let url = directory.appendingPathComponent("synthetic-day-one.zip")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        let entry: [String: Any] = ["uuid": "synthetic-full-disk", "creationDate": "2026-01-01T00:00:00Z",
                                    "text": "Synthetic imported body", "photos": [["identifier": "p", "type": "jpg"]]]
        for (path, data) in [("Journal.json", try JSONSerialization.data(withJSONObject: ["entries": [entry]])),
                             ("photos/p.jpg", jpegData())] {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return url
    }

    private func jpegData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
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

    private func dismiss(_ alert: UIAlertController) async {
        await withCheckedContinuation { continuation in
            alert.dismiss(animated: false) { continuation.resume() }
        }
    }
}
