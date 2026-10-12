import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import Liney

@Suite(.serialized)
@MainActor
struct TimelineRefreshTests {
    @Test func savedEntryAppearsWithoutReappearing() async throws {
        let container = try makeInMemoryContainer()
        let timeline = TimelineViewController(container: container, appLock: AppLockModel())
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: timeline)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitUntil { timeline.contentUnavailableConfiguration != nil }
        #expect(timeline.tableView.numberOfSections == 0)

        let context = ModelContext(container)
        let entry = JournalEntry(title: "Fixture saved elsewhere")
        context.insert(entry)
        try context.save()
        NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
        try await waitUntil { timeline.tableView.numberOfSections != 0 }
        #expect(timeline.tableView.numberOfSections == 1)
        #expect(timeline.contentUnavailableConfiguration == nil)
    }

    @Test func importedEntriesFillInTheTimelineWhileTheImportRuns() async throws {
        let container = try makeInMemoryContainer()
        let timeline = TimelineViewController(container: container, appLock: AppLockModel())
        let window = try mountInWindow(UINavigationController(rootViewController: timeline))
        defer { window.isHidden = true }
        try await waitUntil { timeline.contentUnavailableConfiguration != nil }

        let entryCount = 12
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("synthetic-day-one.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create, pathEncoding: nil)
        let entries: [[String: Any]] = (1...entryCount).map { n in
            ["uuid": "synthetic-\(n)", "creationDate": "2026-01-\(String(format: "%02d", n))T12:00:00Z", "text": "Synthetic body \(n)"]
        }
        let json = try JSONSerialization.data(withJSONObject: ["entries": entries])
        try archive.addEntry(with: "Journal.json", type: .file, uncompressedSize: Int64(json.count)) { position, size in
            json.subdata(in: Int(position)..<(Int(position) + size))
        }

        // Each save records the rows the timeline lists at that moment, and takes long enough for a refresh to land.
        var listedAtSave: [Int] = []
        let importer = DayOneImporter(importRootURL: directory.appendingPathComponent("imports"), saveContext: { context in
            try context.save()
            listedAtSave.append((0..<timeline.tableView.numberOfSections).reduce(0) { $0 + timeline.tableView.numberOfRows(inSection: $1) })
            Thread.sleep(forTimeInterval: 0.06)
        })
        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: .journalDidChange, object: nil, queue: .main) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let importView = ImportJournalViewController(container: container, importer: importer,
                                                     plan: try importer.prepareImport(from: archiveURL))
        let sheet = try mountInWindow(UINavigationController(rootViewController: importView))
        defer { sheet.isHidden = true }
        sheet.layoutIfNeeded()
        try tapBarButton(String(localized: "Import"), in: importView)
        try await waitUntil(timeout: .seconds(5)) { importView.title == String(localized: "Import Complete") }
        try #require(importView.title == String(localized: "Import Complete"))

        #expect(listedAtSave.count == entryCount)
        #expect((listedAtSave.last ?? 0) > 0, "the timeline lists entries before the import finishes")
        #expect(posts > 1 && posts < entryCount, "refreshes are coalesced: \(posts) posts for \(entryCount) entries")
        try await waitUntil { timeline.tableView.numberOfSections == entryCount }
        #expect(timeline.tableView.numberOfSections == entryCount)
    }

    @Test func thumbnailsStayLoadedWhenRowsRedisplay() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let (storage, root) = makeTemporaryPhotoStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).jpegData(withCompressionQuality: 0.8) { renderer in
            UIColor.systemBlue.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let names = try (0..<3).map { _ in try storage.saveJPEG(from: data).fileName }
        for index in 0..<40 {
            let entry = JournalEntry(title: "Photo fixture \(index)", entryDate: .now.addingTimeInterval(Double(-index * 60)))
            context.insert(entry)
            _ = entry.insertPhotoGroup(fileNames: names, in: context)
        }
        try context.save()

        let timeline = TimelineViewController(container: container,
            appLock: AppLockModel(authenticator: DenyingAuthenticator()), storage: storage)
        let navigation = UINavigationController(rootViewController: timeline)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let table = timeline.tableView!
        try await waitUntil { table.numberOfSections != 0 }
        let first = IndexPath(row: 0, section: 0)
        func thumbnails(at indexPath: IndexPath) -> [StoredPhotoView] {
            func images(in view: UIView) -> [StoredPhotoView] {
                (view as? StoredPhotoView).map { [$0] } ?? view.subviews.flatMap { images(in: $0) }
            }
            return table.cellForRow(at: indexPath).map { images(in: $0).filter { !$0.isHidden } } ?? []
        }
        func expectLoadedThumbnails() async throws {
            try await waitUntil { !thumbnails(at: first).contains(where: { $0.image == nil }) }
            #expect(thumbnails(at: first).count == 3)
            #expect(thumbnails(at: first).allSatisfy { $0.image != nil })
        }
        try await expectLoadedThumbnails()

        // Returning from a pushed entry shows the row's thumbnails.
        navigation.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()
        navigation.popViewController(animated: false)
        window.layoutIfNeeded()
        try await expectLoadedThumbnails()

        // UIKit can end and restart a cell's display without asking the data source to configure it again.
        let cell = try #require(table.cellForRow(at: first))
        table.delegate?.tableView?(table, didEndDisplaying: cell, forRowAt: first)
        #expect(thumbnails(at: first).count == 3)
        #expect(thumbnails(at: first).allSatisfy { $0.image != nil })

        // Scrolling the row off screen and back shows its thumbnails again.
        table.setContentOffset(CGPoint(x: 0, y: table.contentSize.height - table.bounds.height), animated: false)
        table.layoutIfNeeded()
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        table.layoutIfNeeded()
        try await expectLoadedThumbnails()
    }
}
