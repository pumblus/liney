import ImageIO
import SwiftData
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
        window.rootViewController = UINavigationController(rootViewController:
            ImportJournalViewController(container: container, summary: summary))
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
        XCTAssertEqual(entry.orderedBlocks[0].text, "Before")
        XCTAssertEqual(entry.orderedBlocks[2].text, "After")

        let photo = try XCTUnwrap(entry.photoGroupBlocks.first?.orderedPhotos.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoStorage.url(for: photo.fileName).path))
        XCTAssertEqual(photo.placeName, "Paris")
        XCTAssertEqual(try XCTUnwrap(photo.locationLatitude), 48.8566, accuracy: 0.0001)
    }

    func testOfficialMarkdownPhotoMarkersDoNotLeaveWrapperText() async throws {
        let archive = try makeArchive(journals: ["Journal.json": [[
            "uuid": "wrapped", "creationDate": "2026-07-06T20:15:00Z",
            "text": "Before\n![](dayone-moment://first)\n![](dayone-moment://second)\nAfter",
            "photos": [["identifier": "first", "md5": "hash-a", "type": "jpeg"],
                       ["identifier": "second", "md5": "hash-b", "type": "jpeg"]]
        ]]], media: ["photos/hash-a.jpeg": makeJPEGData(), "photos/hash-b.jpeg": makeJPEGData()])
        let summary = try await importArchive(archive)
        XCTAssertEqual(summary.importedEntries, 1)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.orderedBlocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(entry.textBlocks.map(\.text), ["Before", "After"])
        XCTAssertEqual(entry.photoGroupBlocks.first?.photos.count, 2)
    }

    func testRetryRestoresMissingPhotoWithoutOverwritingEdits() async throws {
        let raw: [String: Any] = [
            "uuid": "repair", "creationDate": "2026-07-06T20:15:00Z",
            "text": "Before\ndayone-moment://missing\nAfter",
            "photos": [["identifier": "missing", "type": "jpg"]]
        ]
        _ = try await importArchive(makeArchive(journals: ["Journal.json": [raw]]))
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        entry.title = "My edit"
        entry.textBlocks.first?.text = "Edited text"
        try context.save()
        let complete = try makeArchive(journals: ["Journal.json": [raw]],
                                       media: ["photos/missing.jpg": makeJPEGData()])
        _ = try await importArchive(complete)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<JournalEntry>()), 1)
        XCTAssertEqual(entry.title, "My edit")
        XCTAssertEqual(entry.textBlocks.first?.text, "Edited text")
        XCTAssertEqual(entry.photoGroupBlocks.flatMap(\.photos).count, 1)
        _ = try await importArchive(complete)
        XCTAssertEqual(entry.photoGroupBlocks.flatMap(\.photos).count, 1)
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
        XCTAssertEqual(summary.failedPhotos, 1)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.plainTextBody, "Good text.")
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
        XCTAssertEqual(summary.skippedMedia, 1)
        XCTAssertEqual(summary.ignoredMetadata, 2)
        XCTAssertEqual(summary.failedPhotos, 1)
        XCTAssertEqual(summary.issues.map(\.reason), [.invalidDate, .photosUnavailable])
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

    func testReadableMarkdownAndRichTextFallback() async throws {
        let rich: [String: Any] = ["contents": [
            ["attributes": ["line": ["header": 1]], "text": "Heading\n"],
            ["attributes": ["line": ["listStyle": "checkbox", "checked": true]], "text": "Done\n"],
            ["embeddedObjects": [["type": "photo", "identifier": "rich-photo"]]],
            ["text": "Literal *stars* and _underscores_"]
        ]]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rich), as: UTF8.self)
        let archive = try makeArchive(journals: ["Journal.json": [
            ["uuid": "markdown", "creationDate": "2026-01-01T00:00:00Z",
             "text": "# Heading\n- **Bold** and _italic_\n- [x] Done\nVersion 1\\. [Link](https://example.com)"],
            ["uuid": "rich", "creationDate": "2026-01-02T00:00:00Z", "richText": encoded,
             "photos": [["identifier": "rich-photo", "type": "jpg"]]]
        ]], media: ["photos/rich-photo.jpg": makeJPEGData()])
        let summary = try await importArchive(archive)
        XCTAssertEqual(summary.importedEntries, 2)
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let markdown = try XCTUnwrap(entries.first { $0.externalSourceID == "markdown" })
        XCTAssertEqual(markdown.title, "Heading")
        XCTAssertEqual(markdown.plainTextBody, "• Bold and italic\n☑ Done\nVersion 1. Link (https://example.com)")
        let fallback = try XCTUnwrap(entries.first { $0.externalSourceID == "rich" })
        XCTAssertTrue(fallback.plainTextBody.contains("☑ Done"))
        XCTAssertTrue(fallback.plainTextBody.contains("Literal *stars* and _underscores_"))
        XCTAssertEqual(fallback.photoCount, 1)
    }

    func testImportUsesLineyTitleSpacingAndChecklistConventions() async throws {
        let archive = try makeArchive(journals: ["Journal.json": [[
            "uuid": "layout", "creationDate": "2026-01-01T00:00:00Z",
            "text": "# A **quiet** day\n\nFirst paragraph.\n\nSecond paragraph.\n\n![](dayone-moment://p)\n\n- [ ] Testing\n- [x] Finished\n\n---\n\nClosing.",
            "photos": [["identifier": "p", "type": "jpg"]]
        ]]], media: ["photos/p.jpg": makeJPEGData()])
        _ = try await importArchive(archive)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.title, "A quiet day")
        XCTAssertEqual(entry.orderedBlocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(entry.textBlocks.map(\.text), [
            "First paragraph.\n\nSecond paragraph.", "☐ Testing\n☑ Finished\n\n———\n\nClosing."
        ])
    }

    func testHeadingOnlyAndPhotoFirstEntriesPreserveMeaning() async throws {
        let archive = try makeArchive(journals: ["Journal.json": [
            ["uuid": "heading-only", "creationDate": "2026-01-01T00:00:00Z", "text": "# Heading only"],
            ["uuid": "photo-first", "creationDate": "2026-01-01T00:00:00Z",
             "text": "![](dayone-moment://p)\n\n# Heading after photo\n\nBody",
             "photos": [["identifier": "p", "type": "jpg"]]],
            ["uuid": "explicit", "creationDate": "2026-01-01T00:00:00Z", "title": "Explicit", "text": "# Other heading\n\nBody"]
        ]], media: ["photos/p.jpg": makeJPEGData()])
        let summary = try await importArchive(archive)
        XCTAssertEqual(summary.importedEntries, 3)
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let heading = try XCTUnwrap(entries.first { $0.externalSourceID == "heading-only" })
        XCTAssertEqual(heading.title, "Heading only")
        XCTAssertTrue(heading.blocks.isEmpty)
        let photoFirst = try XCTUnwrap(entries.first { $0.externalSourceID == "photo-first" })
        XCTAssertTrue(photoFirst.title.isEmpty)
        XCTAssertEqual(photoFirst.orderedBlocks.map(\.kind), [.photoGroup, .text])
        XCTAssertEqual(photoFirst.plainTextBody, "Heading after photo\n\nBody")
        let explicit = try XCTUnwrap(entries.first { $0.externalSourceID == "explicit" })
        XCTAssertEqual(explicit.title, "Explicit")
        XCTAssertEqual(explicit.plainTextBody, "Other heading\n\nBody")
    }

    func testRichTextTitleAndCodeWhitespaceRemainReadable() async throws {
        let rich: [String: Any] = ["contents": [
            ["attributes": ["line": ["header": 1]], "text": "Rich title\n"],
            ["text": "Literal *stars* and _underscores_\n"],
            ["attributes": ["line": ["listStyle": "checkbox", "checked": false]], "text": "Pending\n"],
            ["attributes": ["line": ["listStyle": "checkbox", "checked": true]], "text": "Done"]
        ]]
        let archive = try makeArchive(journals: ["Journal.json": [
            ["uuid": "rich-layout", "creationDate": "2026-01-01T00:00:00Z", "richText": rich],
            ["uuid": "literal-rich", "creationDate": "2026-01-01T00:00:00Z",
             "richText": ["contents": [["text": "# Not a title\n---\n[Literal](label)"]]]],
            ["uuid": "code-layout", "creationDate": "2026-01-01T00:00:00Z",
             "text": "# Title\r\n\r\nParagraph\r\n\r\n```\r\n  # literal\r\n\r\n    code\r\n```\r\n\r\nEnd"]
        ]])
        _ = try await importArchive(archive)
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let fallback = try XCTUnwrap(entries.first { $0.externalSourceID == "rich-layout" })
        XCTAssertEqual(fallback.title, "Rich title")
        XCTAssertEqual(fallback.plainTextBody, "Literal *stars* and _underscores_\n☐ Pending\n☑ Done")
        let code = try XCTUnwrap(entries.first { $0.externalSourceID == "code-layout" })
        XCTAssertEqual(code.title, "Title")
        XCTAssertTrue(code.plainTextBody.contains("  # literal\n\n    code"))
        let literal = try XCTUnwrap(entries.first { $0.externalSourceID == "literal-rich" })
        XCTAssertTrue(literal.title.isEmpty)
        XCTAssertEqual(literal.plainTextBody, "# Not a title\n---\n[Literal](label)")
    }

    func testRecoverySurvivesReopeningAndPreservesOriginalOrder() async throws {
        let storeURL = temporaryDirectory.appendingPathComponent("recovery.store")
        let configuration = ModelConfiguration(url: storeURL)
        var diskContainer: ModelContainer? = try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self,
                                                               configurations: configuration)
        let raw: [String: Any] = ["uuid": "disk-recovery", "creationDate": "2026-01-01T00:00:00Z",
            "text": "Before\n![](dayone-moment://a)\n![](dayone-moment://b)\n![](dayone-moment://c)\nAfter",
            "photos": [["identifier": "a", "type": "jpg"], ["identifier": "b", "type": "jpg"],
                       ["identifier": "c", "type": "jpg", "location": ["placeName": "Last"]]]]
        let incomplete = try makeArchive(journals: ["Journal.json": [raw]], media: ["photos/c.jpg": makeJPEGData()])
        let importer = DayOneImporter(photoStorage: photoStorage)
        do {
            let diskContext = ModelContext(try XCTUnwrap(diskContainer))
            let summary = await importer.importPreparedArchive(try importer.prepareImport(from: incomplete), into: diskContext) { _ in }
            XCTAssertEqual(summary.failedPhotos, 2)
            let entry = try XCTUnwrap(try diskContext.fetch(FetchDescriptor<JournalEntry>()).first)
            XCTAssertNotNil(entry.dayOnePendingPhotos)
            entry.title = "Edited after import"
            try diskContext.save()
        }
        diskContainer = nil
        diskContainer = try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self, configurations: configuration)
        let reopened = ModelContext(try XCTUnwrap(diskContainer))
        var fullRaw = raw
        fullRaw["photos"] = [["identifier": "a", "type": "jpg", "location": ["placeName": "First"]],
                             ["identifier": "b", "type": "jpg", "location": ["placeName": "Middle"]],
                             ["identifier": "c", "type": "jpg", "location": ["placeName": "Last"]]]
        let full = try makeArchive(journals: ["Journal.json": [fullRaw]], media: [
            "photos/a.jpg": makeJPEGData(), "photos/b.jpg": makeJPEGData(), "photos/c.jpg": makeJPEGData()])
        let summary = await importer.importPreparedArchive(try importer.prepareImport(from: full), into: reopened) { _ in }
        XCTAssertEqual(summary.repairedEntries, 1)
        XCTAssertEqual(summary.recoveredPhotos, 2)
        let entry = try XCTUnwrap(try reopened.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.title, "Edited after import")
        XCTAssertEqual(entry.orderedBlocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(entry.photoGroupBlocks[0].orderedPhotos.map(\.placeName), ["First", "Middle", "Last"])
        XCTAssertNil(entry.dayOnePendingPhotos)
        let photo = entry.photoGroupBlocks[0].orderedPhotos[0]
        _ = entry.deletePhoto(photo, in: reopened)
        try reopened.save()
        let repeated = await importer.importPreparedArchive(try importer.prepareImport(from: full), into: reopened) { _ in }
        XCTAssertEqual(repeated.skippedDuplicates, 1)
        XCTAssertEqual(entry.photoCount, 2, "A photo deliberately deleted after successful import must not return")
    }

    func testRecoveryAfterRemovedAnchorAppendsWithoutChangingText() async throws {
        let raw: [String: Any] = ["uuid": "removed-anchor", "creationDate": "2026-01-01T00:00:00Z",
                                 "text": "Before\ndayone-moment://p\nAfter", "photos": [["identifier": "p", "type": "jpg"]]]
        _ = try await importArchive(makeArchive(journals: ["Journal.json": [raw]]))
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        entry.normalizeBlocks(in: context)
        entry.textBlocks[0].text = "User replacement"
        try context.save()
        let full = try makeArchive(journals: ["Journal.json": [raw]], media: ["photos/p.jpg": makeJPEGData()])
        let summary = try await importArchive(full)
        XCTAssertEqual(entry.plainTextBody, "User replacement")
        XCTAssertEqual(entry.orderedBlocks.map(\.kind), [.text, .photoGroup])
        XCTAssertTrue(summary.issues.contains { $0.reason == .appendedPhotos })
    }

    func testFailedRecoveryCanBeRetriedAndDoesNotDuplicateSuccessfulPhotos() async throws {
        let raw: [String: Any] = ["uuid": "multiple-retries", "creationDate": "2026-01-01T00:00:00Z", "text": "Body",
            "photos": [["identifier": "a", "type": "jpg"], ["identifier": "b", "type": "jpg"]]]
        _ = try await importArchive(makeArchive(journals: ["Journal.json": [raw]]))
        let partial = try makeArchive(journals: ["Journal.json": [raw]], media: ["photos/a.jpg": makeJPEGData()])
        let first = try await importArchive(partial)
        XCTAssertEqual(first.recoveredPhotos, 1)
        XCTAssertEqual(first.failedPhotos, 1)
        let second = try await importArchive(partial)
        XCTAssertEqual(second.recoveredPhotos, 0)
        XCTAssertEqual(second.failedPhotos, 1)
        let full = try makeArchive(journals: ["Journal.json": [raw]], media: ["photos/a.jpg": makeJPEGData(), "photos/b.jpg": makeJPEGData()])
        let last = try await importArchive(full)
        XCTAssertEqual(last.recoveredPhotos, 1)
        XCTAssertEqual(last.failedPhotos, 0)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.photoCount, 2)
        XCTAssertNil(entry.dayOnePendingPhotos)
    }

    func testNestedJournalsResolveTheirOwnPhotoFiles() async throws {
        let photo: [String: Any] = ["identifier": "same-id", "type": "jpg"]
        let archive = try makeArchive(journals: [
            "One/Journal.json": [["uuid": "one", "creationDate": "2026-01-01T00:00:00Z", "photos": [photo]]],
            "Two/Journal.json": [["uuid": "two", "creationDate": "2026-01-01T00:00:00Z", "photos": [photo]]]
        ], media: ["One/photos/same-id.jpg": makeJPEGData(color: .red), "Two/photos/same-id.jpg": makeJPEGData(color: .blue)])
        let summary = try await importArchive(archive)
        XCTAssertEqual(summary.importedEntries, 2)
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let one = try XCTUnwrap(entries.first { $0.externalSourceID == "one" }?.photoGroupBlocks.first?.photos.first)
        let two = try XCTUnwrap(entries.first { $0.externalSourceID == "two" }?.photoGroupBlocks.first?.photos.first)
        XCTAssertNotEqual(try Data(contentsOf: photoStorage.url(for: one.fileName)), try Data(contentsOf: photoStorage.url(for: two.fileName)))
    }

    func testMultiYearPhotoBatchAndRetry() async throws {
        let entries: [[String: Any]] = (0..<120).map { index in
            ["uuid": "year-photo-\(index)", "creationDate": String(format: "%04d-01-01T00:00:00Z", 2000 + index / 12),
             "text": "Before\n![](dayone-moment://p-\(index))\nAfter",
             "photos": [["identifier": "p-\(index)", "type": "jpg"]]]
        }
        let photo = makeJPEGData(size: CGSize(width: 3200, height: 2400))
        let media = Dictionary(uniqueKeysWithValues: (0..<120).map { ("photos/p-\($0).jpg", photo) })
        let archive = try makeArchive(journals: ["Journal.json": entries], media: media)
        let start = Date()
        let summary = try await importArchive(archive)
        XCTAssertEqual(summary.importedEntries, 120)
        XCTAssertEqual(summary.failedPhotos, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<JournalEntry>()).reduce(0) { $0 + $1.photoCount }, 120)
        let retry = try await importArchive(archive)
        XCTAssertEqual(retry.skippedDuplicates, 120)
        print("[PERF] DayOnePhotoBatch syntheticEntries=120 syntheticPhotos=120 importAndRetrySeconds=\(Date().timeIntervalSince(start))")
    }

    func testCancelledPreparationCleansTemporaryArchive() async throws {
        let archive = try makeArchive(journals: ["Journal.json": [["uuid": "cancel-prepare", "creationDate": "2026-01-01T00:00:00Z", "text": "Body"]]])
        let importer = DayOneImporter(photoStorage: photoStorage)
        let baselinePlan = try importer.prepareImport(from: archive)
        let stagingDirectory = baselinePlan.archiveURL.deletingLastPathComponent()
        importer.deleteTemporaryArchive(baselinePlan)
        let before = try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await importer.prepareImportInBackground(from: archive)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)), Set(before))
        let plan = try await importer.prepareImportInBackground(from: archive)
        XCTAssertEqual(plan.entryCount, 1)
        importer.deleteTemporaryArchive(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.archiveURL.path))
    }

    func testOfficialShapeFixtureImportsEveryPhotoAndSupportsRichTextFallback() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "day-one-official-shape", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        var media: [String: Data] = [:]
        for entry in entries {
            for photo in entry["photos"] as? [[String: Any]] ?? [] {
                let hash = try XCTUnwrap(photo["md5"] as? String)
                let ext = try XCTUnwrap(photo["type"] as? String)
                media["photos/\(hash).\(ext)"] = makeJPEGData()
            }
        }
        let archive = try makeArchive(journals: ["Journal.json": entries], media: media)
        let result = try await importArchive(archive)
        XCTAssertEqual(result.importedEntries, 7)
        XCTAssertEqual(result.failedPhotos, 1)
        XCTAssertEqual(result.issues.filter { $0.reason == .photosUnavailable }.count, 1)
        let imported = try context.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(imported.reduce(0) { $0 + $1.photoCount }, 12)
        XCTAssertTrue(imported.allSatisfy { !$0.plainTextBody.contains("dayone-moment://") && !$0.plainTextBody.contains("![](") })
        let richOnly = entries.map { entry -> [String: Any] in
            var value = entry
            value["uuid"] = "rich-only-" + (entry["uuid"] as? String ?? "")
            value.removeValue(forKey: "text")
            return value
        }
        let fallback = try await importArchive(makeArchive(journals: ["Journal.json": richOnly], media: media))
        XCTAssertEqual(fallback.importedEntries, 7)
        XCTAssertEqual(fallback.failedPhotos, 1)
    }

    func testRecoveryKeepsOrderWhenLaterMissingPhotoIsRecoveredFirst() async throws {
        let raw: [String: Any] = ["uuid": "out-of-order-recovery", "creationDate": "2026-01-01T00:00:00Z", "text": "Body",
            "photos": [["identifier": "a", "type": "jpg", "location": ["placeName": "First"]],
                       ["identifier": "b", "type": "jpg", "location": ["placeName": "Second"]]]]
        _ = try await importArchive(makeArchive(journals: ["Journal.json": [raw]]))
        _ = try await importArchive(makeArchive(journals: ["Journal.json": [raw]], media: ["photos/b.jpg": makeJPEGData()]))
        _ = try await importArchive(makeArchive(journals: ["Journal.json": [raw]], media: ["photos/a.jpg": makeJPEGData(), "photos/b.jpg": makeJPEGData()]))
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.photoGroupBlocks[0].orderedPhotos.map(\.placeName), ["First", "Second"])
    }

    func testRecoverySaveFailureRollsBackFilesAndCanRetry() async throws {
        let raw: [String: Any] = ["uuid": "save-recovery", "creationDate": "2026-01-01T00:00:00Z", "text": "Body",
                                 "photos": [["identifier": "p", "type": "jpg"]]]
        _ = try await importArchive(makeArchive(journals: ["Journal.json": [raw]]))
        let full = try makeArchive(journals: ["Journal.json": [raw]], media: ["photos/p.jpg": makeJPEGData()])
        let filesBefore = Set(try FileManager.default.subpathsOfDirectory(atPath: temporaryDirectory.path))
        struct SyntheticSaveFailure: Error { }
        let failing = DayOneImporter(photoStorage: photoStorage, saveContext: { _ in throw SyntheticSaveFailure() })
        let failure = await failing.importPreparedArchive(try failing.prepareImport(from: full), into: context) { _ in }
        XCTAssertEqual(failure.failedEntries, 1)
        XCTAssertEqual(failure.recoveredPhotos, 0)
        XCTAssertEqual(failure.issues.last?.reason, .saveFailed)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.photoCount, 0)
        XCTAssertNotNil(entry.dayOnePendingPhotos)
        let filesAfter = Set(try FileManager.default.subpathsOfDirectory(atPath: temporaryDirectory.path))
        XCTAssertEqual(filesAfter.filter { $0.hasSuffix(".jpg") }, filesBefore.filter { $0.hasSuffix(".jpg") })
        let retry = try await importArchive(full)
        XCTAssertEqual(retry.recoveredPhotos, 1)
    }

    func testUnsupportedVideoReferenceIsNotARecoverablePhoto() async throws {
        let archive = try makeArchive(journals: ["Journal.json": [[
            "uuid": "video-reference", "creationDate": "2026-01-01T00:00:00Z",
            "text": "Body\n![](dayone-moment://video)", "videos": [["identifier": "video"]],
            "userActivity": ["stepCount": 2], "tags": ["tag"]
        ]]])
        let importer = DayOneImporter(photoStorage: photoStorage)
        let plan = try importer.prepareImport(from: archive)
        XCTAssertEqual(plan.unsupportedMediaCount, 1)
        XCTAssertEqual(plan.ignoredMetadataCount, 2)
        let result = await importer.importPreparedArchive(plan, into: context) { _ in }
        XCTAssertEqual(result.skippedMedia, 1)
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertEqual(result.ignoredMetadata, 2)
        let entry = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertNil(entry.dayOnePendingPhotos)
    }

    func testExistingStoreUpgradesWithoutChangingEntriesOrPhotos() throws {
        let url = temporaryDirectory.appendingPathComponent("legacy.store")
        var legacyContainer: ModelContainer? = try ModelContainer(
            for: LegacyDayOneSchema.JournalEntry.self, LegacyDayOneSchema.EntryBlock.self, LegacyDayOneSchema.EntryPhoto.self,
            configurations: ModelConfiguration(url: url))
        let originalID = UUID()
        do {
            let legacy = ModelContext(try XCTUnwrap(legacyContainer))
            let entry = LegacyDayOneSchema.JournalEntry(id: originalID, externalSourceID: "legacy-source", title: "Legacy fixture")
            let text = LegacyDayOneSchema.EntryBlock(text: "Synthetic legacy body", entry: entry)
            let group = LegacyDayOneSchema.EntryBlock(kind: .photoGroup, sortIndex: 1, entry: entry)
            let photo = LegacyDayOneSchema.EntryPhoto(fileName: "fixture.jpg", block: group)
            group.photos = [photo]
            entry.blocks = [text, group]
            legacy.insert(entry)
            try legacy.save()
        }
        legacyContainer = nil
        let upgraded = try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self,
                                          configurations: ModelConfiguration(url: url))
        let upgradedContext = ModelContext(upgraded)
        let entry = try XCTUnwrap(try upgradedContext.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(entry.id, originalID)
        XCTAssertEqual(entry.externalSourceID, "legacy-source")
        XCTAssertEqual(entry.title, "Legacy fixture")
        XCTAssertEqual(entry.plainTextBody, "Synthetic legacy body")
        XCTAssertEqual(entry.photoCount, 1)
        XCTAssertEqual(entry.photoGroupBlocks.first?.photos.first?.fileName, "fixture.jpg")
        XCTAssertNil(entry.dayOnePendingPhotos)
        try upgradedContext.save()
    }

    func testMigrationSummaryAndConfirmationRendering() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let plan = DayOneImportPlan(archiveURL: temporaryDirectory, entryCount: 7, photoCount: 12, unsupportedMediaCount: 2, ignoredMetadataCount: 4)
        var summary = DayOneImportSummary(importedEntries: 6, failedEntries: 1, processedEntries: 7, totalEntries: 7)
        summary.failedPhotos = 2
        summary.issues = [DayOneImportIssue(sourceID: "FIXTURE-SOURCE-ID", entryNumber: 3,
                                           entryDate: Date(timeIntervalSince1970: 0), reason: .photosUnavailable)]
        do {
            for screen in ["confirmation", "summary", "confirmation-large", "summary-large"] {
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                let controller = ImportJournalViewController(container: container,
                    plan: screen.hasPrefix("confirmation") ? plan : nil,
                    summary: screen.hasPrefix("summary") ? summary : nil)
                controller.traitOverrides.preferredContentSizeCategory = screen.hasSuffix("large") ? .accessibilityExtraLarge : .large
                controller.overrideUserInterfaceStyle = screen.hasSuffix("large") ? .dark : .light
                window.rootViewController = UINavigationController(rootViewController: controller)
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(150))
                let view = try XCTUnwrap(window.rootViewController?.view)
                view.frame = window.bounds
                view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                    XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "migration-\(screen)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
            }
        }
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
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 1) { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

// Frozen pre-recovery schema; keep unchanged to exercise additive store upgrades.
private enum LegacyDayOneSchema {
    @Model
    final class JournalEntry: Identifiable {
        @Attribute(.unique) var id: UUID
        var externalSourceID: String?
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

}
