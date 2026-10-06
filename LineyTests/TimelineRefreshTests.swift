import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import XCTest
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
        for _ in 0..<100 where timeline.contentUnavailableConfiguration == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(timeline.tableView.numberOfSections == 0)

        let context = ModelContext(container)
        let entry = JournalEntry(title: "Fixture saved elsewhere")
        context.insert(entry)
        try context.save()
        NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
        for _ in 0..<100 where timeline.tableView.numberOfSections == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(timeline.tableView.numberOfSections == 1)
        #expect(timeline.contentUnavailableConfiguration == nil)
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
        for _ in 0..<100 where table.numberOfSections == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let first = IndexPath(row: 0, section: 0)
        func thumbnails(at indexPath: IndexPath) -> [StoredPhotoView] {
            func images(in view: UIView) -> [StoredPhotoView] {
                (view as? StoredPhotoView).map { [$0] } ?? view.subviews.flatMap { images(in: $0) }
            }
            return table.cellForRow(at: indexPath).map { images(in: $0).filter { !$0.isHidden } } ?? []
        }
        func expectLoadedThumbnails() async throws {
            for _ in 0..<100 where thumbnails(at: first).contains(where: { $0.image == nil }) {
                try await Task.sleep(for: .milliseconds(20))
            }
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
