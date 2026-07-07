import ImageIO
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Liney

@MainActor
final class JournalEntryFlowTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: JournalEntry.self,
            EntryBlock.self,
            EntryPhoto.self,
            configurations: configuration
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    func testCreateEditAndReopenEntry() throws {
        let entryDate = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        let entry = JournalEntry(entryDate: entryDate)
        context.insert(entry)

        entry.title = "Morning"
        entry.setBody("Coffee before the walk.", in: context)
        try context.save()

        let reopened = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(reopened.title, "Morning")
        XCTAssertEqual(reopened.plainTextBody, "Coffee before the walk.")
        XCTAssertEqual(reopened.rowTitle, "Morning")
        XCTAssertEqual(reopened.rowSubtitle, "Coffee before the walk.")
    }

    func testLocalizationCatalogCoversEnglishAndSimplifiedChinese() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Liney/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")

        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        var failures: [String] = []
        for (key, rawValue) in strings.sorted(by: { $0.key < $1.key }) {
            guard let value = rawValue as? [String: Any] else {
                failures.append("\(key): invalid entry")
                continue
            }
            if value["extractionState"] as? String == "stale" {
                failures.append("\(key): stale")
            }
            let localizations = value["localizations"] as? [String: Any]
            for locale in ["en", "zh-Hans"] {
                guard let localizedValue = localizations?[locale] as? [String: Any],
                      let stringUnit = localizedValue["stringUnit"] as? [String: Any],
                      stringUnit["state"] as? String == "translated",
                      let text = stringUnit["value"] as? String,
                      !text.isEmpty else {
                    failures.append("\(key): missing \(locale)")
                    continue
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testBlankNewEntryIsDiscarded() throws {
        let entry = JournalEntry(title: "   ")
        context.insert(entry)

        XCTAssertTrue(discardBlankNewEntry(entry, in: context))
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<JournalEntry>()).count, 0)
    }

    func testEntryDateEditsPreserveTimedDateAndNormalizeAllDayDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let entry = JournalEntry(
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9, minute: 30)))
        )

        let timedDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20, minute: 15)))
        entry.setEntryDate(timedDate, calendar: calendar)
        XCTAssertFalse(entry.isAllDay)
        XCTAssertEqual(entry.entryDate, timedDate)

        entry.setAllDay(true, calendar: calendar)
        XCTAssertTrue(entry.isAllDay)
        XCTAssertEqual(entry.entryDate, try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))))

        let allDayDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 17, minute: 45)))
        entry.setEntryDate(allDayDate, calendar: calendar)
        XCTAssertEqual(entry.entryDate, try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8))))

        entry.setAllDay(false, calendar: calendar)
        entry.setEntryDate(allDayDate, calendar: calendar)
        XCTAssertEqual(entry.entryDate, allDayDate)
    }

    func testTimelineGroupingAndDelete() throws {
        let calendar = Calendar(identifier: .gregorian)
        let newest = JournalEntry(
            title: "Newest",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9)))
        )
        let olderSameDay = JournalEntry(
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 8))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 8)))
        )
        let laterSameDay = JournalEntry(
            title: "Later",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20)))
        )

        [olderSameDay, newest, laterSameDay].forEach { context.insert($0) }
        olderSameDay.setBody("Body summary", in: context)
        try context.save()

        let groups = groupEntriesByDay([olderSameDay, newest, laterSameDay], calendar: calendar)
        XCTAssertEqual(groups.map(\.date), [
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7))),
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6)))
        ])
        XCTAssertEqual(groups[1].entries.map(\.rowTitle), ["Later", "Body summary"])

        context.delete(laterSameDay)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(remaining.map(\.rowTitle).sorted(), ["Body summary", "Newest"])
    }

    func testTimelineOrdersTimedEntriesByTimeAndAllDayEntriesByCreatedAt() throws {
        let calendar = Calendar(identifier: .gregorian)
        let timedMorning = JournalEntry(
            title: "Morning",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        )
        let timedEvening = JournalEntry(
            title: "Evening",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20)))
        )
        let allDayOlder = JournalEntry(
            title: "All Day Older",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 12))),
            isAllDay: true,
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 10)))
        )
        let allDayNewer = JournalEntry(
            title: "All Day Newer",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 12))),
            isAllDay: true,
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 11)))
        )

        let groups = groupEntriesByDay([allDayOlder, timedMorning, allDayNewer, timedEvening], calendar: calendar)

        XCTAssertEqual(groups.flatMap { $0.entries.map(\.title) }, ["Evening", "Morning", "All Day Newer", "All Day Older"])
    }

    func testLocationDisplayTextRequiresMainLocationName() {
        let namedLocation = JournalEntry(locationName: "  Paris  ", locationLatitude: 48.8566, locationLongitude: 2.3522)
        XCTAssertEqual(namedLocation.locationDisplayText, "Paris")

        let coordinatesOnly = JournalEntry(locationLatitude: 48.8566, locationLongitude: 2.3522)
        XCTAssertNil(coordinatesOnly.locationDisplayText)

        let emptyLocation = JournalEntry(locationName: "   ")
        XCTAssertNil(emptyLocation.locationDisplayText)
    }

    func testSearchMatchesTitleAndBodyOnlyAndKeepsTimelineOrder() throws {
        let calendar = Calendar(identifier: .gregorian)
        let titleMatch = JournalEntry(
            title: "Train Notes",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        )
        let bodyMatch = JournalEntry(
            title: "Lunch",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9)))
        )
        let dateOnlyMatch = JournalEntry(
            title: "Picnic",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9)))
        )

        [titleMatch, bodyMatch, dateOnlyMatch].forEach { context.insert($0) }
        bodyMatch.setBody("Found a quiet train station.", in: context)
        dateOnlyMatch.setBody("River walk.", in: context)
        try context.save()

        let entries = [dateOnlyMatch, bodyMatch, titleMatch]
        let groups = groupEntriesByDay(searchJournalEntries(entries, matching: "TRAIN"), calendar: calendar)

        XCTAssertEqual(groups.flatMap { $0.entries.map(\.title) }, ["Lunch", "Train Notes"])
        XCTAssertTrue(groups[0].entries[0] === bodyMatch)
        XCTAssertTrue(searchJournalEntries(entries, matching: "2026").isEmpty)
        XCTAssertEqual(searchJournalEntries(entries, matching: "   ").count, 3)
    }

    func testInsertPhotoGroupSplitsFocusedTextBlockAndPreservesPhotoOrder() throws {
        let entry = JournalEntry()
        context.insert(entry)
        entry.setBody("Hello world", in: context)
        let textBlock = try XCTUnwrap(entry.textBlocks.first)

        let insertion = try XCTUnwrap(entry.insertPhotoGroup(
            fileNames: ["first.jpg", "second.jpg"],
            focusedTextBlockID: textBlock.id,
            cursorOffset: 5,
            in: context
        ))
        try context.save()

        let blocks = entry.orderedBlocks
        XCTAssertEqual(blocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(blocks[0].text, "Hello")
        XCTAssertEqual(blocks[1].orderedPhotos.map(\.fileName), ["first.jpg", "second.jpg"])
        XCTAssertEqual(blocks[2].text, " world")
        XCTAssertEqual(insertion.followingTextBlock?.id, blocks[2].id)

        let reopened = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(reopened.orderedBlocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(reopened.photoGroupBlocks.first?.orderedPhotos.map(\.fileName), ["first.jpg", "second.jpg"])
    }

    func testInsertPhotoGroupAtFocusedEndAndWithoutFocusAppends() throws {
        let focusedEntry = JournalEntry()
        context.insert(focusedEntry)
        focusedEntry.setBody("End", in: context)
        let textBlock = try XCTUnwrap(focusedEntry.textBlocks.first)

        let focusedInsertion = try XCTUnwrap(focusedEntry.insertPhotoGroup(
            fileNames: ["end.jpg"],
            focusedTextBlockID: textBlock.id,
            cursorOffset: 3,
            in: context
        ))
        XCTAssertNil(focusedInsertion.followingTextBlock)
        XCTAssertEqual(focusedEntry.orderedBlocks.map(\.kind), [.text, .photoGroup])

        let noFocusEntry = JournalEntry()
        context.insert(noFocusEntry)
        noFocusEntry.setBody("Body", in: context)
        _ = noFocusEntry.insertPhotoGroup(fileNames: ["tail.jpg"], in: context)

        XCTAssertEqual(noFocusEntry.orderedBlocks.map(\.kind), [.text, .photoGroup])
        XCTAssertEqual(noFocusEntry.photoGroupBlocks.first?.orderedPhotos.first?.fileName, "tail.jpg")
    }

    func testNormalizeBlocksDropsEmptyTextAndMergesAdjacentText() throws {
        let entry = JournalEntry()
        let first = EntryBlock(sortIndex: 0, text: "First", entry: entry)
        let empty = EntryBlock(sortIndex: 1, text: "   ", entry: entry)
        let second = EntryBlock(sortIndex: 2, text: "Second", entry: entry)
        entry.blocks = [first, empty, second]
        context.insert(entry)
        [first, empty, second].forEach { context.insert($0) }

        entry.normalizeBlocks(in: context)
        try context.save()

        XCTAssertEqual(entry.orderedBlocks.count, 1)
        XCTAssertEqual(entry.orderedBlocks.first?.text, "First\nSecond")
    }

    func testPhotoOnlyEntryIsNotBlankAndPreviewsThreePhotos() throws {
        let entry = JournalEntry()
        context.insert(entry)

        _ = entry.insertPhotoGroup(fileNames: ["1.jpg", "2.jpg", "3.jpg", "4.jpg"], in: context)
        try context.save()

        XCTAssertFalse(entry.isBlank)
        XCTAssertEqual(entry.previewPhotos.map(\.fileName), ["1.jpg", "2.jpg", "3.jpg"])
    }

    func testPhotoMetadataVisibilityRequiresCaptureTimeOrPlaceText() {
        XCTAssertFalse(EntryPhoto(fileName: "plain.jpg").hasVisibleMetadata)
        let coordinatesOnly = EntryPhoto(fileName: "gps.jpg", locationLatitude: 48.8566, locationLongitude: 2.3522)
        XCTAssertFalse(coordinatesOnly.hasVisibleMetadata)
        XCTAssertTrue(coordinatesOnly.hasUsableEntryInfo)

        let captured = EntryPhoto(fileName: "captured.jpg", capturedAt: Date())
        XCTAssertTrue(captured.hasVisibleMetadata)
        XCTAssertTrue(captured.hasUsableEntryInfo)

        let placed = EntryPhoto(fileName: "placed.jpg", placeName: "  Paris  ")
        XCTAssertEqual(placed.placeDisplayText, "Paris")
        XCTAssertTrue(placed.hasVisibleMetadata)
    }

    func testApplyPhotoInfoUpdatesEntryDateAndNamedLocation() throws {
        let calendar = Calendar(identifier: .gregorian)
        let originalDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let capturedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20, minute: 15)))
        let entry = JournalEntry(entryDate: originalDate, isAllDay: true)
        let photo = EntryPhoto(
            fileName: "paris.jpg",
            capturedAt: capturedAt,
            placeName: "  Paris  ",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )

        entry.applyInfo(from: photo)

        XCTAssertFalse(entry.isAllDay)
        XCTAssertEqual(entry.entryDate, capturedAt)
        XCTAssertEqual(entry.locationName, "Paris")
        XCTAssertEqual(entry.locationLatitude, 48.8566)
        XCTAssertEqual(entry.locationLongitude, 2.3522)
    }

    func testPhotoInfoPromptUsesTimeAndLocationThresholds() throws {
        let calendar = Calendar(identifier: .gregorian)
        let entryDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        let entry = JournalEntry(
            entryDate: entryDate,
            locationName: "Paris",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )

        let exactlyTwelveHours = EntryPhoto(
            fileName: "same-day.jpg",
            capturedAt: entryDate.addingTimeInterval(12 * 60 * 60),
            placeName: "Paris",
            locationLatitude: 48.8567,
            locationLongitude: 2.3523
        )
        XCTAssertFalse(entry.shouldPromptForPhotoInfo(from: exactlyTwelveHours))

        let moreThanTwelveHours = EntryPhoto(
            fileName: "different-time.jpg",
            capturedAt: entryDate.addingTimeInterval(12 * 60 * 60 + 1)
        )
        XCTAssertTrue(entry.shouldPromptForPhotoInfo(from: moreThanTwelveHours))

        let farLocation = EntryPhoto(
            fileName: "london.jpg",
            placeName: "London",
            locationLatitude: 51.5074,
            locationLongitude: -0.1278
        )
        XCTAssertTrue(entry.shouldPromptForPhotoInfo(from: farLocation))

        let farCoordinatesOnly = EntryPhoto(
            fileName: "gps-only.jpg",
            locationLatitude: 51.5074,
            locationLongitude: -0.1278
        )
        XCTAssertTrue(entry.shouldPromptForPhotoInfo(from: farCoordinatesOnly))
    }

    func testPhotoInfoPromptUsesMissingEntryLocationAndKeepsGeocodeFailureCoordinatesInternal() {
        let missingLocationEntry = JournalEntry()
        let placedPhoto = EntryPhoto(
            fileName: "placed.jpg",
            placeName: "Paris",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )
        XCTAssertTrue(missingLocationEntry.shouldPromptForPhotoInfo(from: placedPhoto))

        let coordinatesOnlyPhoto = EntryPhoto(
            fileName: "coordinates-only.jpg",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )
        XCTAssertTrue(missingLocationEntry.shouldPromptForPhotoInfo(from: coordinatesOnlyPhoto))

        missingLocationEntry.applyInfo(from: coordinatesOnlyPhoto)
        XCTAssertNil(missingLocationEntry.locationDisplayText)
        XCTAssertEqual(missingLocationEntry.locationLatitude, 48.8566)
        XCTAssertEqual(missingLocationEntry.locationLongitude, 2.3522)

        let namedLocationEntry = JournalEntry(locationName: "Paris")
        namedLocationEntry.applyInfo(from: coordinatesOnlyPhoto)
        XCTAssertNil(namedLocationEntry.locationDisplayText)
        XCTAssertEqual(namedLocationEntry.locationLatitude, 48.8566)
        XCTAssertEqual(namedLocationEntry.locationLongitude, 2.3522)

        missingLocationEntry.hasShownPhotoInfoPrompt = true
        XCTAssertFalse(missingLocationEntry.shouldPromptForPhotoInfo(from: placedPhoto))
    }

    func testPhotoInfoPromptCandidateOnlyConsidersFirstAddedPhoto() {
        let entry = JournalEntry(locationName: "Paris", locationLatitude: 48.8566, locationLongitude: 2.3522)
        let firstPhoto = EntryPhoto(fileName: "first.jpg", placeName: "Paris", locationLatitude: 48.8567, locationLongitude: 2.3523)
        let laterDifferentPhoto = EntryPhoto(fileName: "later.jpg", placeName: "London", locationLatitude: 51.5074, locationLongitude: -0.1278)

        XCTAssertNil(entry.photoInfoPromptCandidate(from: [firstPhoto, laterDifferentPhoto]))
        XCTAssertTrue(entry.photoInfoPromptCandidate(from: [laterDifferentPhoto, firstPhoto]) === laterDifferentPhoto)
    }

    func testDeletePhotoRemovesPhotoAndReindexesGroup() throws {
        let entry = JournalEntry()
        context.insert(entry)
        _ = entry.insertPhotoGroup(fileNames: ["1.jpg", "2.jpg", "3.jpg"], in: context)
        let block = try XCTUnwrap(entry.photoGroupBlocks.first)
        let deletedPhoto = block.orderedPhotos[1]

        let deletedFileName = entry.deletePhoto(deletedPhoto, in: context)
        try context.save()

        XCTAssertEqual(deletedFileName, "2.jpg")
        XCTAssertEqual(entry.photoGroupBlocks.count, 1)
        XCTAssertEqual(block.orderedPhotos.map(\.fileName), ["1.jpg", "3.jpg"])
        XCTAssertEqual(block.orderedPhotos.map(\.displayOrder), [0, 1])
    }

    func testDeleteLastPhotoRemovesEmptyPhotoGroup() throws {
        let entry = JournalEntry()
        context.insert(entry)
        _ = entry.insertPhotoGroup(fileNames: ["only.jpg"], in: context)
        let photo = try XCTUnwrap(entry.photoGroupBlocks.first?.orderedPhotos.first)

        entry.deletePhoto(photo, in: context)
        try context.save()

        XCTAssertTrue(entry.photoGroupBlocks.isEmpty)
        XCTAssertTrue(entry.orderedBlocks.isEmpty)
    }

    func testPhotoStorageCreatesJPEGAndReportsPartialFailure() throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let validImageData = makeJPEGData()

        let result = storage.saveJPEGs(from: [validImageData, Data("not an image".utf8)])

        XCTAssertEqual(result.fileNames.count, 1)
        XCTAssertEqual(result.failedCount, 1)
        let copiedURL = storage.url(for: try XCTUnwrap(result.fileNames.first))
        XCTAssertEqual(copiedURL.pathExtension, "jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        XCTAssertNotNil(CGImageSourceCreateWithURL(copiedURL as CFURL, nil))

        try storage.delete(fileName: try XCTUnwrap(result.fileNames.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedURL.path))
    }

    func testPhotoStoragePreservesCaptureTimeAndGPSMetadata() throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let imageData = makeJPEGData(
            capturedAtText: "2026:07:06 20:15:00",
            latitude: 48.8566,
            longitude: 2.3522
        )

        let result = storage.saveJPEGs(from: [imageData])
        let photo = try XCTUnwrap(result.photos.first)

        XCTAssertEqual(photo.capturedAt, exifDate("2026:07:06 20:15:00"))
        XCTAssertEqual(try XCTUnwrap(photo.locationLatitude), 48.8566, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(photo.locationLongitude), 2.3522, accuracy: 0.0001)
    }

    func testPhotoImportResultCreatesPartialFailureAlert() {
        XCTAssertNil(PhotoImportResult(fileNames: ["ok.jpg"], failedCount: 0).alert)
        XCTAssertEqual(PhotoImportResult(fileNames: ["ok.jpg"], failedCount: 1).alert?.failedCount, 1)
        XCTAssertEqual(PhotoImportResult(fileNames: ["ok.jpg"], failedCount: 2).alert?.failedCount, 2)
    }

    func testPhotoGroupLayoutThresholds() {
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 0), 1)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 1), 1)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 2), 2)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 3), 3)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 4), 2)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 5), 3)
    }

    func testPhotoGroupLayoutPlanUsesSquareCells() {
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 1).map(\.columnSpan), [1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 2).map(\.columnSpan), [1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 3).map(\.columnSpan), [1, 1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 4).map(\.columnSpan), [1, 1, 1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 5).map(\.columnSpan), [1, 1, 1, 1, 1])

        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 1).map(\.aspectRatio), [1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 2).map(\.aspectRatio), [1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 3).map(\.aspectRatio), [1, 1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 4).map(\.aspectRatio), [1, 1, 1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 5).map(\.aspectRatio), [1, 1, 1, 1, 1])
    }

    func testThreePhotoLayoutSmokeRendersOnSimulator() throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let result = storage.saveJPEGs(from: [
            makeJPEGData(size: CGSize(width: 96, height: 48), color: .systemRed),
            makeJPEGData(size: CGSize(width: 48, height: 96), color: .systemGreen),
            makeJPEGData(size: CGSize(width: 96, height: 96), color: .systemBlue)
        ])
        XCTAssertEqual(result.failedCount, 0)

        let block = EntryBlock(kind: .photoGroup)
        block.photos = result.photos.enumerated().map { index, photo in
            EntryPhoto(fileName: photo.fileName, displayOrder: index, block: block)
        }

        let renderer = ImageRenderer(content: PhotoGroupBlockView(block: block, storage: storage) { _ in }
            .background(Color.white)
            .frame(width: 320))
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.height, 104, accuracy: 1)
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 106, y: 52)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 214, y: 52)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 0, y: 0)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 108, y: 0)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 216, y: 0)))
        let attachment = XCTAttachment(image: image)
        attachment.name = "Three-photo layout smoke"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPreviewThumbnailsStayInsideFixedBoxes() throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let result = storage.saveJPEGs(from: [
            makeJPEGData(size: CGSize(width: 96, height: 48), color: .systemRed),
            makeJPEGData(size: CGSize(width: 48, height: 96), color: .systemGreen),
            makeJPEGData(size: CGSize(width: 96, height: 96), color: .systemBlue)
        ])
        XCTAssertEqual(result.failedCount, 0)
        let photos = result.photos.enumerated().map { index, photo in
            EntryPhoto(fileName: photo.fileName, displayOrder: index)
        }

        let renderer = ImageRenderer(content: HStack(spacing: 6) {
            ForEach(photos) { photo in
                Color.clear
                    .frame(width: 48, height: 48)
                    .overlay {
                        StoredPhotoThumbnail(photo: photo, storage: storage, cornerRadius: 6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .background(Color.white))
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.height, 48, accuracy: 1)
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 51, y: 24)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 105, y: 24)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 0, y: 0)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 54, y: 0)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 108, y: 0)))
    }

    private func makeJPEGData(size: CGSize = CGSize(width: 32, height: 24), color: UIColor = .systemBlue) -> Data {
        UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 1) { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func rgbaPixel(in image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.translateBy(x: CGFloat(-x), y: CGFloat(y + 1 - cgImage.height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }

        return pixel
    }

    private func isWhite(_ pixel: [UInt8]) -> Bool {
        pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245
    }

    private func makeJPEGData(capturedAtText: String, latitude: Double, longitude: Double) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: capturedAtText
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E"
            ]
        ]
        CGImageDestinationAddImage(destination, image.cgImage!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
