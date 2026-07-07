import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import Liney

@MainActor
final class DayOneImportTests: XCTestCase {
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

    func testImportsOrderedTextAndPhotoBlocks() async throws {
        let archiveURL = try makeArchive(
            journals: [
                "Journal.json": [
                    [
                        "uuid": "entry-1",
                        "creationDate": "2026-07-06T20:15:00Z",
                        "modifiedDate": "2026-07-06T21:00:00Z",
                        "text": "Before\ndayone-moment://photo-a\nAfter",
                        "location": [
                            "userLabel": "Paris",
                            "latitude": 48.8566,
                            "longitude": 2.3522
                        ],
                        "photos": [
                            [
                                "identifier": "photo-a",
                                "type": "jpg",
                                "date": "2026-07-06T20:10:00Z",
                                "location": [
                                    "placeName": "Paris",
                                    "latitude": 48.8566,
                                    "longitude": 2.3522
                                ]
                            ]
                        ]
                    ]
                ]
            ],
            media: ["photos/photo-a.jpg": makeJPEGData()]
        )

        let summary = try await importArchive(archiveURL)

        XCTAssertEqual(summary.importedEntries, 1)
        XCTAssertEqual(summary.skippedMedia, 0)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.externalSourceID, "entry-1")
        XCTAssertEqual(entry.locationDisplayText, "Paris")
        XCTAssertEqual(entry.orderedBlocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(entry.orderedBlocks[0].text, "Before\n")
        XCTAssertEqual(entry.orderedBlocks[2].text, "\nAfter")

        let photo = try XCTUnwrap(entry.photoGroupBlocks.first?.orderedPhotos.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoStorage.url(for: photo.fileName).path))
        XCTAssertEqual(photo.placeName, "Paris")
        XCTAssertEqual(try XCTUnwrap(photo.locationLatitude), 48.8566, accuracy: 0.0001)
    }

    func testImportsFallbackAttachmentsAndSkipsDuplicateReimport() async throws {
        let archiveURL = try makeArchive(
            journals: [
                "Journal.json": [
                    [
                        "uuid": "entry-2",
                        "creationDate": "2026-07-07T09:00:00Z",
                        "text": "Body first.",
                        "photos": [
                            ["identifier": "second", "type": "jpg", "orderInEntry": 1],
                            ["identifier": "first", "type": "jpg", "orderInEntry": 0]
                        ]
                    ]
                ]
            ],
            media: [
                "photos/first.jpg": makeJPEGData(color: .systemRed),
                "photos/second.jpg": makeJPEGData(color: .systemGreen)
            ]
        )

        let firstSummary = try await importArchive(archiveURL)
        let secondSummary = try await importArchive(archiveURL)

        XCTAssertEqual(firstSummary.importedEntries, 1)
        XCTAssertEqual(secondSummary.importedEntries, 0)
        XCTAssertEqual(secondSummary.skippedDuplicates, 1)
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].orderedBlocks.map(\.kind), [.text, .photoGroup])
        XCTAssertEqual(entries[0].photoGroupBlocks.first?.orderedPhotos.count, 2)
    }

    func testMultipleDayOneJSONFilesMergeIntoOneTimeline() async throws {
        let archiveURL = try makeArchive(journals: [
            "Journal.json": [
                ["uuid": "entry-a", "creationDate": "2026-07-06T09:00:00Z", "text": "A"]
            ],
            "Other/Journal.json": [
                ["uuid": "entry-b", "creationDate": "2026-07-07T09:00:00Z", "text": "B"]
            ]
        ])

        let summary = try await importArchive(archiveURL)

        XCTAssertEqual(summary.importedEntries, 2)
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(Set(entries.map(\.externalSourceID)), ["entry-a", "entry-b"])
    }

    func testPreflightRejectsZipWithoutDayOneJSON() throws {
        let archiveURL = try makeArchive(journals: [:], media: ["notes.txt": Data("hello".utf8)])
        let importer = DayOneImporter(photoStorage: photoStorage)

        XCTAssertThrowsError(try importer.prepareImport(from: archiveURL)) { error in
            XCTAssertEqual(error.localizedDescription, DayOneImportError.missingDayOneJSON.localizedDescription)
        }
    }

    func testPreflightRejectsDayOneJSONWithoutEntries() throws {
        let archiveURL = try makeArchive(journals: ["Journal.json": []])
        let importer = DayOneImporter(photoStorage: photoStorage)

        XCTAssertThrowsError(try importer.prepareImport(from: archiveURL)) { error in
            XCTAssertEqual(error.localizedDescription, DayOneImportError.missingDayOneJSON.localizedDescription)
        }
    }

    func testDuplicateNormalizedArchivePathsDoNotCrashImport() async throws {
        let archiveURL = try makeArchive(
            journals: [
                "Journal.json": [
                    [
                        "uuid": "entry-duplicate-path",
                        "creationDate": "2026-07-08T09:00:00Z",
                        "text": "Photo",
                        "photos": [["identifier": "photo-a", "type": "jpg"]]
                    ]
                ]
            ],
            media: [
                "photos/photo-a.jpg": makeJPEGData(color: .systemRed),
                "Photos/photo-a.jpg": makeJPEGData(color: .systemGreen)
            ]
        )

        let summary = try await importArchive(archiveURL)

        XCTAssertEqual(summary.importedEntries, 1)
        XCTAssertEqual(summary.skippedMedia, 0)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.photoGroupBlocks.first?.orderedPhotos.count, 1)
    }

    func testBadEntryAndPhotoFailureAreCountedWithoutBlockingGoodText() async throws {
        let archiveURL = try makeArchive(
            journals: [
                "Journal.json": [
                    ["uuid": "bad-entry", "text": "Missing date"],
                    [
                        "uuid": "entry-3",
                        "creationDate": "2026-07-08T09:00:00Z",
                        "text": "Good text.",
                        "videos": [["identifier": "video"]],
                        "tags": ["travel"],
                        "weather": ["temperatureCelsius": 22],
                        "photos": [
                            ["identifier": "missing-photo", "type": "jpg"]
                        ]
                    ]
                ]
            ]
        )

        let summary = try await importArchive(archiveURL)

        XCTAssertEqual(summary.importedEntries, 1)
        XCTAssertEqual(summary.failedEntries, 1)
        XCTAssertEqual(summary.skippedMedia, 4)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.plainTextBody, "Good text.")
        XCTAssertTrue(entry.photoGroupBlocks.isEmpty)
    }

    func testCancellationKeepsAlreadyCommittedEntries() async throws {
        let archiveURL = try makeArchive(journals: [
            "Journal.json": [
                ["uuid": "entry-4", "creationDate": "2026-07-08T09:00:00Z", "text": "First"],
                ["uuid": "entry-5", "creationDate": "2026-07-09T09:00:00Z", "text": "Second"]
            ]
        ])
        let importer = DayOneImporter(photoStorage: photoStorage)
        let plan = try importer.prepareImport(from: archiveURL)
        var task: Task<DayOneImportSummary, Never>!

        task = Task {
            await importer.importPreparedArchive(plan, into: context) { progress in
                if progress.processedEntries == 1 {
                    task.cancel()
                }
            }
        }

        let summary = await task.value

        XCTAssertTrue(summary.wasCancelled)
        XCTAssertEqual(summary.importedEntries, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<JournalEntry>()).count, 1)
    }

    private func importArchive(_ archiveURL: URL) async throws -> DayOneImportSummary {
        let importer = DayOneImporter(photoStorage: photoStorage)
        let plan = try importer.prepareImport(from: archiveURL)
        return await importer.importPreparedArchive(plan, into: context) { _ in }
    }

    private func makeArchive(
        journals: [String: [[String: Any]]],
        media: [String: Data] = [:]
    ) throws -> URL {
        let archiveURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        let archive = try Archive(url: archiveURL, accessMode: .create, pathEncoding: nil)

        for (path, entries) in journals {
            let data = try JSONSerialization.data(withJSONObject: ["entries": entries])
            try add(data, path: path, to: archive)
        }

        for (path, data) in media {
            try add(data, path: path, to: archive)
        }

        return archiveURL
    }

    private func add(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count)
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private func makeJPEGData(size: CGSize = CGSize(width: 32, height: 24), color: UIColor = .systemBlue) -> Data {
        UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 1) { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
