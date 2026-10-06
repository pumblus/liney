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

    func testFastExportTransitionsFromProcessingToAnchoredShareSheet() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        let source = UIBarButtonItem(systemItem: .action)
        presenter.navigationItem.rightBarButtonItem = source
        window.rootViewController = UINavigationController(rootViewController: presenter)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        let flow = ExportJournalFlow(presenter: presenter, container: container,
                                     appLock: AppLockModel(authenticator: ApprovingAuthenticator()),
                                     sourceBarButtonItem: source)
        var finished = false
        flow.onFinished = { finished = true }
        flow.start()
        for _ in 0..<100 {
            if presenter.presentedViewController is ProcessingViewController { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let progress = try XCTUnwrap(presenter.presentedViewController as? ProcessingViewController)
        XCTAssertTrue(progress.isModalInPresentation)
        for _ in 0..<300 {
            if presenter.presentedViewController is UIActivityViewController { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let activity = try XCTUnwrap(presenter.presentedViewController as? UIActivityViewController)
        XCTAssertTrue(activity.popoverPresentationController?.barButtonItem === source)
        XCTAssertFalse(finished)
        await withCheckedContinuation { continuation in
            activity.dismiss(animated: false) { continuation.resume() }
        }
        activity.completionWithItemsHandler?(nil, false, nil, nil)
        for _ in 0..<100 {
            if finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(finished)
    }

    func testShareSheetAnchorsToInitiatingBarButtonItem() throws {
        let presenter = UIViewController()
        let source = UIBarButtonItem(systemItem: .action)
        presenter.navigationItem.rightBarButtonItem = source
        let flow = ExportJournalFlow(
            presenter: presenter, container: container, appLock: AppLockModel(),
            sourceBarButtonItem: source
        )

        let activity = flow.makeShareController(for: temporaryDirectory.appendingPathComponent("synthetic.zip"))
        let popover = try XCTUnwrap(activity.popoverPresentationController)

        XCTAssertTrue(popover.barButtonItem === source)
        XCTAssertNil(popover.sourceView)
    }

    func testShareSheetWithoutBarButtonUsesPresenterFallback() throws {
        let presenter = UIViewController()
        presenter.view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let flow = ExportJournalFlow(presenter: presenter, container: container, appLock: AppLockModel())

        let activity = flow.makeShareController(for: temporaryDirectory.appendingPathComponent("synthetic.zip"))
        let popover = try XCTUnwrap(activity.popoverPresentationController)

        XCTAssertNil(popover.barButtonItem)
        XCTAssertTrue(popover.sourceView === presenter.view)
        XCTAssertEqual(popover.sourceRect, CGRect(x: 300, y: 400, width: 1, height: 1))
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

        let export = try exporter.export(entries: [JournalExportEntry(entry: entry)], exportedAt: exportedAt)

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

    func testExportsFromSnapshotEntries() throws {
        let calendar = utcCalendar()
        let exportRootURL = temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        let exporter = JournalExporter(
            photoStorage: photoStorage,
            exportRootURL: exportRootURL,
            calendar: calendar
        )
        let exportedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7)))
        let entry = JournalExportEntry(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            title: "Cleanup Check",
            entryDate: exportedAt,
            isAllDay: true,
            createdAt: exportedAt,
            locationText: nil,
            locationLatitude: nil,
            locationLongitude: nil,
            blocks: [.text("Current export.")]
        )

        let export = try exporter.export(entries: [entry], exportedAt: exportedAt)

        XCTAssertTrue(FileManager.default.fileExists(atPath: export.url.path))
    }

    func testMissingPhotoFailureRemovesPartialExportDirectory() throws {
        let exportRootURL = temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        let exporter = JournalExporter(photoStorage: photoStorage, exportRootURL: exportRootURL)
        let entry = JournalExportEntry(
            id: UUID(),
            title: "Missing photo",
            entryDate: .now,
            isAllDay: false,
            createdAt: .now,
            locationText: nil,
            locationLatitude: nil,
            locationLongitude: nil,
            blocks: [.text("Before"), .photoGroup(["missing.jpg"]), .text("After")]
        )

        XCTAssertThrowsError(try exporter.export(entries: [entry])) { error in
            XCTAssertEqual(error.localizedDescription, JournalExportError.missingPhoto.localizedDescription)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportRootURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: exportRootURL, includingPropertiesForKeys: nil), [])
    }

    func testPerformanceBatchExport500SyntheticEntries() throws {
        let syntheticEntries = makePerformanceEntries(count: 500)
        var durationsMilliseconds: [Double] = []

        for iteration in 0..<3 {
            let runDirectory = temporaryDirectory
                .appendingPathComponent("performance-export-\(iteration)", isDirectory: true)
            let exportRootURL = runDirectory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

            do {
                defer { try? FileManager.default.removeItem(at: runDirectory) }

                let exporter = JournalExporter(
                    photoStorage: photoStorage,
                    exportRootURL: exportRootURL,
                    calendar: utcCalendar()
                )
                let exportedAt = try XCTUnwrap(utcCalendar().date(from: DateComponents(year: 2026, month: 7, day: 7)))
                let start = DispatchTime.now().uptimeNanoseconds
                let export = try exporter.export(entries: syntheticEntries, exportedAt: exportedAt)
                let end = DispatchTime.now().uptimeNanoseconds

                XCTAssertTrue(FileManager.default.fileExists(atPath: export.url.path))
                durationsMilliseconds.append(Double(end - start) / 1_000_000)
                exporter.deleteExport(export)
            }
        }

        logPerformance(
            "JournalExport",
            entries: syntheticEntries.count,
            durationsMilliseconds: durationsMilliseconds
        )
    }

    func testDeleteTemporaryExportsRemovesExportRoot() throws {
        let exportRootURL = temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        let staleDirectoryURL = exportRootURL.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDirectoryURL, withIntermediateDirectories: true)
        let exporter = JournalExporter(photoStorage: photoStorage, exportRootURL: exportRootURL)

        exporter.deleteTemporaryExports()

        XCTAssertFalse(FileManager.default.fileExists(atPath: exportRootURL.path))
    }

    private func extract(_ path: String, from archive: Archive) throws -> Data {
        let entry = try XCTUnwrap(archive[path])
        var data = Data()
        let checksum = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        XCTAssertEqual(checksum, entry.checksum)
        return data
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makePerformanceEntries(count: Int) -> [JournalExportEntry] {
        let calendar = utcCalendar()
        let baseDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!

        return (0..<count).map { index in
            JournalExportEntry(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                title: "Synthetic entry \(index)",
                entryDate: baseDate.addingTimeInterval(Double(index) * 60),
                isAllDay: false,
                createdAt: baseDate.addingTimeInterval(Double(index) * 60),
                locationText: nil,
                locationLatitude: nil,
                locationLongitude: nil,
                blocks: [.text("Synthetic entry body \(index)")]
            )
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
}
