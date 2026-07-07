import ImageIO
import SwiftData
import UIKit
import XCTest
import ZIPFoundation
@testable import Liney

@MainActor
final class JournalExportTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var temporaryDirectory: URL!
    private var photoStorage: PhotoStorage!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: JournalEntry.self,
            EntryBlock.self,
            EntryPhoto.self,
            configurations: configuration
        )
        context = ModelContext(container)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        photoStorage = PhotoStorage(baseURL: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        photoStorage = nil
        context = nil
        container = nil
        temporaryDirectory = nil
    }

    func testExportsMarkdownZipWithPhotosAndDeletesTemporaryExport() throws {
        let calendar = utcCalendar()
        let exportRootURL = temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        let exporter = JournalExporter(
            photoStorage: photoStorage,
            exportRootURL: exportRootURL,
            calendar: calendar
        )
        let exportedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 10)))
        let entryID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let entryDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20, minute: 15)))
        let photo = try XCTUnwrap(photoStorage.saveJPEGs(from: [makeJPEGData()]).photos.first)
        let entry = JournalEntry(
            id: entryID,
            title: "Morning Walk",
            entryDate: entryDate,
            createdAt: entryDate,
            locationName: "Paris",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )
        let before = EntryBlock(kind: .text, sortIndex: 0, text: "Before photo.", entry: entry)
        let photoBlock = EntryBlock(kind: .photoGroup, sortIndex: 1, entry: entry)
        let entryPhoto = EntryPhoto(fileName: photo.fileName, displayOrder: 0, block: photoBlock)
        let after = EntryBlock(kind: .text, sortIndex: 2, text: "After photo.", entry: entry)
        photoBlock.photos = [entryPhoto]
        entry.blocks = [before, photoBlock, after]
        context.insert(entry)
        [before, photoBlock, after].forEach { context.insert($0) }
        context.insert(entryPhoto)
        try context.save()

        let export = try exporter.export(entries: [entry], exportedAt: exportedAt)

        XCTAssertEqual(export.url.lastPathComponent, "liney-export-2026-07-07.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.url.path))
        let archive = try XCTUnwrap(Archive(url: export.url, accessMode: .read, pathEncoding: nil))
        let entrySlug = "2026-07-06-201500-00000000-0000-0000-0000-000000000001"
        let markdownPath = "entries/\(entrySlug).md"
        let photoPath = "media/\(entrySlug)/photo-001.jpg"
        XCTAssertNotNil(archive[markdownPath])
        XCTAssertNotNil(archive[photoPath])

        let markdown = try String(data: extract(markdownPath, from: archive), encoding: .utf8)
        XCTAssertEqual(markdown, """
        ---
        date: "2026-07-06T20:15:00Z"
        all_day: false
        location: "Paris"
        latitude: 48.8566
        longitude: 2.3522
        ---

        # Morning Walk

        Before photo.

        ![Photo 1](../media/\(entrySlug)/photo-001.jpg)

        After photo.

        """)
        XCTAssertNotNil(CGImageSourceCreateWithData(try extract(photoPath, from: archive) as CFData, nil))

        exporter.deleteExport(export)

        XCTAssertFalse(FileManager.default.fileExists(atPath: export.directoryURL.path))
    }

    private func extract(_ path: String, from archive: Archive) throws -> Data {
        let entry = try XCTUnwrap(archive[path])
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { chunk in
            data.append(chunk)
        }
        return data
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeJPEGData(size: CGSize = CGSize(width: 32, height: 24), color: UIColor = .systemBlue) -> Data {
        UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 1) { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
