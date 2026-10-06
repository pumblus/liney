import SwiftData
import Testing
import UIKit
@testable import Liney

private struct SyntheticFailure: Error { }

/// A file system that refuses to move the named files, as when a file is locked or permissions changed.
private final class UnmovableFileManager: FileManager, @unchecked Sendable {
    private let unmovable: Set<String>

    init(unmovable: Set<String>) {
        self.unmovable = unmovable
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if unmovable.contains(srcURL.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// The launch sweep that moves Orphaned Photo Files into the Photo Quarantine (#12).
@Suite
@MainActor
final class PhotoQuarantineTests {
    private let directory: URL
    private let storage: PhotoStorage
    private let calendar: Calendar
    private let launchedAt = Date(timeIntervalSince1970: 1_791_331_200) // 2026-10-07T00:00:00Z
    private var today: Date { launchedAt.addingTimeInterval(3_600) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = PhotoStorage(baseURL: directory)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        self.calendar = calendar
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func `only unreferenced photo files from before launch move into the quarantine`() throws {
        let referenced = try (0..<4).map { _ in try photoFile() }
        let orphans = try (0..<2).map { _ in try photoFile() }
        let newOrphan = try photoFile(modified: launchedAt.addingTimeInterval(1))

        sweep(referencing: referenced)

        #expect(try photoFiles() == Set(referenced + [newOrphan]))
        #expect(try quarantinedFiles(on: "2026-10-07") == Set(orphans))
    }

    @Test
    func `photos saved from another context are never moved`() throws {
        let container = try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let editor = ModelContext(container)
        let entry = JournalEntry(title: "Synthetic title")
        editor.insert(entry)
        let referenced = try (0..<3).map { _ in try photoFile() }
        _ = entry.insertPhotoGroup(photos: referenced.map { PhotoGroupItem(fileName: $0) }, in: editor)
        try editor.save()
        let orphan = try photoFile()

        storage.sweepOrphanedPhotoFiles(launchedAt: launchedAt, now: today, calendar: calendar) {
            try PhotoStorage.referencedFileNames(in: ModelContext(container))
        }

        #expect(try photoFiles() == Set(referenced))
        #expect(try quarantinedFiles(on: "2026-10-07") == [orphan])
    }

    @Test(arguments: ["notes.txt", "photo.jpg", "\(UUID().uuidString).png", "\(UUID().uuidString).jpg.tmp",
                      "\(UUID().uuidString.lowercased()).jpg"])
    func `files not named as stored photos are never moved`(name: String) throws {
        let referenced = try (0..<4).map { _ in try photoFile() }
        try photoFile(named: name)

        sweep(referencing: referenced)

        #expect(try photoFiles().contains(name))
        #expect(!FileManager.default.fileExists(atPath: storage.photoQuarantineURL.path))
    }

    @Test
    func `a failing photo fetch moves nothing`() throws {
        // Without the fetch, the orphan would be the only candidate of two files, and the old day would be purged.
        let orphan = try photoFile()
        try photoFile(named: "notes.txt")
        try quarantineDay("2026-08-01")

        storage.sweepOrphanedPhotoFiles(launchedAt: launchedAt, now: today, calendar: calendar) { throw SyntheticFailure() }

        #expect(try photoFiles() == [orphan, "notes.txt"])
        #expect(try quarantineDays() == ["2026-08-01"])
    }

    @Test
    func `more than half the photo files unreferenced moves nothing`() throws {
        let referenced = try (0..<2).map { _ in try photoFile() }
        let orphans = try (0..<3).map { _ in try photoFile() }

        sweep(referencing: referenced)

        #expect(try photoFiles() == Set(referenced + orphans))
        #expect(!FileManager.default.fileExists(atPath: storage.photoQuarantineURL.path))
    }

    @Test
    func `exactly half the photo files unreferenced still moves them`() throws {
        let referenced = try (0..<2).map { _ in try photoFile() }
        let orphans = try (0..<2).map { _ in try photoFile() }

        sweep(referencing: referenced)

        #expect(try quarantinedFiles(on: "2026-10-07") == Set(orphans))
    }

    @Test
    func `quarantined days older than 30 days are deleted`() throws {
        for day in ["2025-12-31", "2026-09-05", "2026-09-06", "2026-09-07", "2026-10-07"] {
            try quarantineDay(day)
        }

        sweep(referencing: [])

        #expect(try quarantineDays() == ["2026-09-07", "2026-10-07"])
    }

    @Test
    func `a file that cannot be moved is retried by the next sweep`() throws {
        let referenced = try (0..<4).map { _ in try photoFile() }
        let stuck = try photoFile()
        let orphan = try photoFile()

        PhotoStorage(fileManager: UnmovableFileManager(unmovable: [stuck]), baseURL: directory)
            .sweepOrphanedPhotoFiles(launchedAt: launchedAt, now: today, calendar: calendar) { Set(referenced) }

        #expect(try photoFiles() == Set(referenced + [stuck]))
        #expect(try quarantinedFiles(on: "2026-10-07") == [orphan])

        sweep(referencing: referenced)

        #expect(try photoFiles() == Set(referenced))
        #expect(try quarantinedFiles(on: "2026-10-07") == [orphan, stuck])

        sweep(referencing: referenced)

        #expect(try photoFiles() == Set(referenced))
        #expect(try quarantinedFiles(on: "2026-10-07") == [orphan, stuck])
    }

    @Test
    func `the quarantine is excluded from backup`() throws {
        let referenced = try (0..<2).map { _ in try photoFile() }
        _ = try photoFile()

        sweep(referencing: referenced)

        let values = try storage.photoQuarantineURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: - Fixtures

    private func sweep(referencing fileNames: [String]) {
        storage.sweepOrphanedPhotoFiles(launchedAt: launchedAt, now: today, calendar: calendar) { Set(fileNames) }
    }

    @discardableResult
    private func photoFile(named name: String = "\(UUID().uuidString).jpg", modified: Date? = nil) throws -> String {
        try FileManager.default.createDirectory(at: storage.photoDirectoryURL, withIntermediateDirectories: true)
        let url = storage.url(for: name)
        try Data("synthetic".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified ?? launchedAt.addingTimeInterval(-60)],
                                              ofItemAtPath: url.path)
        return name
    }

    private func quarantineDay(_ name: String) throws {
        let day = storage.photoQuarantineURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: day.appendingPathComponent("\(UUID().uuidString).jpg"))
    }

    private func photoFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: storage.photoDirectoryURL.path))
    }

    private func quarantineDays() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: storage.photoQuarantineURL.path))
    }

    private func quarantinedFiles(on day: String) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            atPath: storage.photoQuarantineURL.appendingPathComponent(day, isDirectory: true).path))
    }
}
