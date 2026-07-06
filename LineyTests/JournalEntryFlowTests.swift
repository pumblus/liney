import ImageIO
import SwiftData
import UIKit
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
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 4), 2)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 5), 3)
    }

    private func makeJPEGData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }
}
