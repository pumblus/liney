import ImageIO
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import Liney

@MainActor
final class DayOneImportTests: XCTestCase {
    func testCancelledImportSummaryRendering() async throws {
        let summary = DayOneImportSummary(importedEntries: 1, processedEntries: 1, totalEntries: 2, wasCancelled: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView:
            ImportJournalProgressView(isImporting: false,
                progress: DayOneImportProgress(processedEntries: 1, totalEntries: 2),
                summary: summary, cancel: {}, done: {})
                .environment(\.locale, Locale(identifier: "en"))
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        let view = try XCTUnwrap(window.rootViewController?.view)
        view.frame = window.bounds
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "cancelled-import-summary"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(image.size.width.isZero)
    }

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

    func testPreflightRejectsDayOneJSONWithInvalidCRC() throws {
        let archiveURL = try makeArchive(journals: [
            "Journal.json": [
                ["uuid": "entry-crc", "creationDate": "2026-07-08T09:00:00Z", "text": "CRC"]
            ]
        ])
        try corruptCentralDirectoryCRC(for: "Journal.json", in: archiveURL)
        let importer = DayOneImporter(photoStorage: photoStorage)

        XCTAssertThrowsError(try importer.prepareImport(from: archiveURL))
    }

    func testImportsAllDayDateComponentsInDeviceCalendar() async throws {
        let archiveURL = try makeArchive(journals: [
            "Journal.json": [
                [
                    "uuid": "entry-all-day-zone",
                    "creationDate": "2026-07-08T01:00:00Z",
                    "isAllDay": true,
                    "timeZone": "Pacific/Kiritimati",
                    "text": "All-day memory"
                ]
            ]
        ])

        let summary = try await importArchive(archiveURL)

        XCTAssertEqual(summary.importedEntries, 1)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertTrue(entry.isAllDay)

        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let creationDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-08T01:00:00Z"))
        let components = sourceCalendar.dateComponents([.year, .month, .day], from: creationDate)
        var expectedCalendar = Calendar(identifier: .gregorian)
        expectedCalendar.timeZone = Calendar.current.timeZone
        let expectedDate = try XCTUnwrap(expectedCalendar.date(from: components))
        XCTAssertEqual(entry.entryDate, expectedDate)
    }

    func testImportsAllDayDateComponentsFromWesternTimeZone() async throws {
        let archiveURL = try makeArchive(journals: [
            "Journal.json": [
                [
                    "uuid": "entry-all-day-west",
                    "creationDate": "2026-07-08T06:30:00Z",
                    "isAllDay": true,
                    "timeZone": "America/Los_Angeles",
                    "text": "Western all-day memory"
                ]
            ]
        ])

        let summary = try await importArchive(archiveURL)

        XCTAssertEqual(summary.importedEntries, 1)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertTrue(entry.isAllDay)

        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let creationDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-08T06:30:00Z"))
        let components = sourceCalendar.dateComponents([.year, .month, .day], from: creationDate)
        var expectedCalendar = Calendar(identifier: .gregorian)
        expectedCalendar.timeZone = Calendar.current.timeZone
        let expectedDate = try XCTUnwrap(expectedCalendar.date(from: components))
        XCTAssertEqual(entry.entryDate, expectedDate)
    }

    func testTimedImportPreservesAbsoluteTimestamp() async throws {
        let archiveURL = try makeArchive(journals: [
            "Journal.json": [
                [
                    "uuid": "entry-timed-zone",
                    "creationDate": "2026-07-08T01:00:00Z",
                    "isAllDay": false,
                    "timeZone": "Pacific/Kiritimati",
                    "text": "Timed memory"
                ]
            ]
        ])

        let summary = try await importArchive(archiveURL)

        XCTAssertEqual(summary.importedEntries, 1)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertFalse(entry.isAllDay)
        XCTAssertEqual(entry.entryDate, try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-08T01:00:00Z")))
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

    func testImportSkipsPhotoWithInvalidCRC() async throws {
        let archiveURL = try makeArchive(
            journals: [
                "Journal.json": [
                    [
                        "uuid": "entry-photo-crc",
                        "creationDate": "2026-07-08T09:00:00Z",
                        "text": "Good text.\ndayone-moment://bad-photo",
                        "photos": [["identifier": "bad-photo", "type": "jpg"]]
                    ]
                ]
            ],
            media: ["photos/bad-photo.jpg": makeJPEGData()]
        )
        try corruptCentralDirectoryCRC(for: "photos/bad-photo.jpg", in: archiveURL)

        let summary = try await importArchive(archiveURL)

        XCTAssertEqual(summary.importedEntries, 1)
        XCTAssertEqual(summary.skippedMedia, 1)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.plainTextBody, "Good text.\n")
        XCTAssertTrue(entry.photoGroupBlocks.isEmpty)
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

        let retrySummary = try await importArchive(archiveURL)

        XCTAssertEqual(retrySummary.importedEntries, 1)
        XCTAssertEqual(retrySummary.skippedDuplicates, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<JournalEntry>()).count, 2)
    }

    func testPerformanceBatchImport500SyntheticEntries() async throws {
        let syntheticEntries = try makePerformanceEntries(count: 500)
        var durationsMilliseconds: [Double] = []

        for iteration in 0..<3 {
            let runDirectory = temporaryDirectory
                .appendingPathComponent("performance-import-\(iteration)", isDirectory: true)
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

            do {
                defer { try? FileManager.default.removeItem(at: runDirectory) }

                let archiveURL = try makeArchive(
                    journals: ["Journal.json": syntheticEntries],
                    directory: runDirectory
                )
                let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
                let runContainer = try ModelContainer(
                    for: JournalEntry.self,
                    EntryBlock.self,
                    EntryPhoto.self,
                    configurations: configuration
                )
                let runContext = ModelContext(runContainer)
                let runStorage = PhotoStorage(
                    baseURL: runDirectory.appendingPathComponent("Photos", isDirectory: true)
                )
                let importer = DayOneImporter(photoStorage: runStorage)
                let start = DispatchTime.now().uptimeNanoseconds
                let plan = try importer.prepareImport(from: archiveURL)
                let summary = await importer.importPreparedArchive(plan, into: runContext) { _ in }
                let end = DispatchTime.now().uptimeNanoseconds

                XCTAssertEqual(summary.importedEntries, 500)
                XCTAssertEqual(summary.failedEntries, 0)
                durationsMilliseconds.append(Double(end - start) / 1_000_000)
            }
        }

        logPerformance(
            "DayOneImport",
            entries: syntheticEntries.count,
            durationsMilliseconds: durationsMilliseconds
        )
    }

    private func importArchive(_ archiveURL: URL) async throws -> DayOneImportSummary {
        let importer = DayOneImporter(photoStorage: photoStorage)
        let plan = try importer.prepareImport(from: archiveURL)
        return await importer.importPreparedArchive(plan, into: context) { _ in }
    }

    private func makeArchive(
        journals: [String: [[String: Any]]],
        media: [String: Data] = [:],
        directory: URL? = nil
    ) throws -> URL {
        let archiveURL = (directory ?? temporaryDirectory)
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

    private func makePerformanceEntries(count: Int) throws -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let baseDate = try XCTUnwrap(formatter.date(from: "2026-01-01T00:00:00Z"))

        return (0..<count).map { index in
            [
                "uuid": "performance-entry-\(index)",
                "creationDate": formatter.string(from: baseDate.addingTimeInterval(Double(index) * 60)),
                "text": "Synthetic entry body \(index)"
            ]
        }
    }

    private func logPerformance(
        _ label: String,
        entries: Int,
        durationsMilliseconds: [Double]
    ) {
        guard !durationsMilliseconds.isEmpty else { return }
        let sortedDurations = durationsMilliseconds.sorted()
        let median = sortedDurations[sortedDurations.count / 2]
        let durations = durationsMilliseconds
            .map { String(format: "%.2f", $0) }
            .joined(separator: ",")
        print(
            "[PERF] \(label) environment=iOS-Simulator syntheticEntries=\(entries) " +
                "repeats=\(durationsMilliseconds.count) " +
                "durations_ms=[\(durations)] median_ms=\(String(format: "%.2f", median))"
        )
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

    private func corruptCentralDirectoryCRC(for path: String, in archiveURL: URL) throws {
        var data = try Data(contentsOf: archiveURL)
        var offset = 0

        while offset + 46 <= data.count {
            let isCentralDirectoryHeader = data[offset] == 0x50 &&
                data[offset + 1] == 0x4b &&
                data[offset + 2] == 0x01 &&
                data[offset + 3] == 0x02

            guard isCentralDirectoryHeader else {
                offset += 1
                continue
            }

            let nameLength = Int(littleEndianUInt16(in: data, at: offset + 28))
            let extraLength = Int(littleEndianUInt16(in: data, at: offset + 30))
            let commentLength = Int(littleEndianUInt16(in: data, at: offset + 32))
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength

            guard nameEnd <= data.count else { break }
            let entryPath = String(data: Data(data[nameStart..<nameEnd]), encoding: .utf8)
            if entryPath == path {
                data[offset + 16] = data[offset + 16] ^ UInt8(0xff)
                try data.write(to: archiveURL)
                return
            }

            offset += 46 + nameLength + extraLength + commentLength
        }

        XCTFail("Missing central directory entry for \(path)")
    }

    private func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func makeJPEGData(size: CGSize = CGSize(width: 32, height: 24), color: UIColor = .systemBlue) -> Data {
        UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 1) { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
