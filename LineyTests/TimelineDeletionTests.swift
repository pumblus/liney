import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Liney

@Suite(.serialized)
@MainActor
struct TimelineDeletionTests {

    @Test(arguments: [false, true])
    func openIPadEntryUsesEditorConfirmation(searching: Bool) async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let entry = JournalEntry(title: "Open fixture")
        context.insert(entry)
        try context.save()
        let timeline = TimelineViewController(container: container,
            appLock: AppLockModel(authenticator: DenyingAuthenticator()))
        let editor = EntryEditorViewController(entry: entry, isNew: false, context: context)
        let split = UISplitViewController(style: .doubleColumn)
        split.preferredDisplayMode = .oneBesideSecondary
        split.setViewController(UINavigationController(rootViewController: timeline), for: .primary)
        split.setViewController(UINavigationController(rootViewController: editor), for: .secondary)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = split
        window.makeKeyAndVisible()
        defer {
            timeline.navigationItem.searchController?.isActive = false
            window.isHidden = true
        }
        window.layoutIfNeeded()
        try #require(!split.isCollapsed)
        if searching {
            try await Task.sleep(for: .milliseconds(100))
            let search = try #require(timeline.navigationItem.searchController)
            search.isActive = true
            search.searchBar.text = "Open"
            timeline.updateSearchResults(for: search)
            try await Task.sleep(for: .milliseconds(500))
            #expect(search.presentingViewController != nil)
        }
        func titleInput(in view: UIView) -> UITextView? {
            if let input = view as? UITextView, input.accessibilityLabel == String(localized: "Title (optional)") { return input }
            return view.subviews.lazy.compactMap { titleInput(in: $0) }.first
        }
        let input = try #require(titleInput(in: editor.view))
        input.text = "Pending edit"
        input.delegate?.textViewDidChange?(input)
        timeline.confirmDeleteEntry(id: entry.id)
        let confirmation = try await waitForAlert(from: editor)
        #expect(!context.hasChanges)
        #expect(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).first?.title == "Pending edit")
        await withCheckedContinuation { continuation in
            confirmation.dismiss(animated: false) { continuation.resume() }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<JournalEntry>()) == 1)
    }

    @Test(arguments: [false, true])
    func swipeRequiresConfirmationAndDeletesOnlySelectedEntry(searching: Bool) async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PhotoStorage(baseURL: root)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32)).jpegData(withCompressionQuality: 0.8) { renderer in
            UIColor.systemBlue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }
        let name = try storage.saveJPEG(from: data).fileName
        let selected = JournalEntry(title: "Selected fixture", entryDate: .now)
        let other = JournalEntry(title: "Other fixture", entryDate: .distantPast)
        let selectedID = selected.id
        let otherID = other.id
        context.insert(selected); context.insert(other)
        _ = selected.insertPhotoGroup(fileNames: [name], in: context)
        try context.save()

        let timeline = TimelineViewController(container: container,
            appLock: AppLockModel(authenticator: DenyingAuthenticator()), storage: storage)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: timeline)
        window.makeKeyAndVisible()
        defer {
            timeline.navigationItem.searchController?.isActive = false
            window.isHidden = true
        }
        timeline.loadViewIfNeeded()
        if searching {
            try await Task.sleep(for: .milliseconds(100))
            let search = try #require(timeline.navigationItem.searchController)
            search.isActive = true
            search.searchBar.text = "Selected"
            timeline.updateSearchResults(for: search)
            try await Task.sleep(for: .milliseconds(500))
            #expect(search.presentingViewController != nil)
        }
        let expectedSections = searching ? 1 : 2
        for _ in 0..<100 {
            if timeline.tableView.numberOfSections == expectedSections { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(timeline.tableView.numberOfSections == expectedSections)
        let swipe = try #require(timeline.tableView(timeline.tableView,
            trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 0, section: 0)))
        #expect(!swipe.performsFirstActionWithFullSwipe)
        let action = try #require(swipe.actions.first)
        #expect(action.style == .destructive)
        var completed: Bool?
        action.handler(action, timeline.tableView) { completed = $0 }
        #expect(completed == false)
        let confirmation = try await waitForAlert(from: timeline)
        #expect(confirmation.actions.map(\.style).contains(.cancel))
        #expect(confirmation.actions.map(\.style).contains(.destructive))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<JournalEntry>()) == 2)
        #expect(FileManager.default.fileExists(atPath: storage.url(for: name).path))
        // Cancelling/dismissing confirmation never executes the deletion callback.
        await withCheckedContinuation { continuation in
            confirmation.dismiss(animated: false) { continuation.resume() }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<JournalEntry>()) == 2)
        timeline.deleteEntry(id: selectedID)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        #expect(remaining.map(\.id) == [otherID])
        #expect(!FileManager.default.fileExists(atPath: storage.url(for: name).path))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<EntryPhoto>()) == 0)
        for _ in 0..<100 {
            if timeline.tableView.numberOfSections == expectedSections - 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(timeline.tableView.numberOfSections == expectedSections - 1)
        // A stale action for an already deleted identity must not delete a replacement row.
        timeline.deleteEntry(id: selectedID)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<JournalEntry>()) == 1)
    }
}
