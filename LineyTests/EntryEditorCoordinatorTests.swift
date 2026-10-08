import SwiftData
import Testing
import UIKit
@testable import Liney

/// Two or more scene roots share one coordinator; fake scene handles record activation,
/// because a real scene request cannot run in unit tests.
@Suite(.serialized)
@MainActor
struct EntryEditorCoordinatorTests {
    let container: ModelContainer
    let first: JournalEntry
    let second: JournalEntry
    let coordinator = EntryEditorCoordinator()

    init() throws {
        container = try makeInMemoryContainer()
        let context = ModelContext(container)
        first = JournalEntry(title: "Synthetic first", entryDate: Date(timeIntervalSince1970: 1_700_100_000))
        second = JournalEntry(title: "Synthetic second", entryDate: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(first); context.insert(second)
        try context.save()
    }

    /// One window: its root, timeline, fake scene handle, and the coordinator's view of it.
    @MainActor struct Window {
        let root: JournalSplitViewController
        let timeline: TimelineViewController
        let scene: FakeScene
        let editors: SceneEditors
        let window: UIWindow

        var secondary: UINavigationController? { root.viewController(for: .secondary) as? UINavigationController }
        var openEditor: EntryEditorViewController? { root.openEditor }
        var showsNoEntrySelected: Bool { secondary?.topViewController?.title == String(localized: "No Entry Selected") }

        /// Taps the only row of `day` (0 is the newest).
        func select(day: Int) async throws {
            timeline.tableView(timeline.tableView, didSelectRowAt: IndexPath(row: 0, section: day))
            try await settle()
        }
        func settle() async throws {
            root.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
        }
        func type(_ text: String) throws {
            let editor = try #require(openEditor)
            let input = try #require(descendants(editor.view, as: BlockTextView.self).first)
            input.text = text
            input.delegate?.textViewDidChange?(input)
        }
    }

    func open(_ sizeClass: UIUserInterfaceSizeClass = .regular, sections: Int = 2,
              storage: PhotoStorage = makeTemporaryPhotoStorage().storage) async throws -> Window {
        let scene = FakeScene()
        let editors = coordinator.connectScene(scene)
        let timeline = TimelineViewController(container: container, appLock: AppLockModel(authenticator: DenyingAuthenticator()),
                                              storage: storage, editors: editors)
        let root = JournalSplitViewController(timeline: timeline)
        root.traitOverrides.horizontalSizeClass = sizeClass
        let live = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: live)
        window.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        window.rootViewController = root
        window.makeKeyAndVisible()
        for _ in 0..<100 {
            if timeline.tableView.numberOfSections == sections { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(timeline.tableView.numberOfSections == sections)
        let opened = Window(root: root, timeline: timeline, scene: scene, editors: editors, window: window)
        try await opened.settle()
        return opened
    }

    func close(_ windows: Window...) async {
        for window in windows {
            if let presented = window.root.presentedViewController {
                await withCheckedContinuation { continuation in
                    presented.dismiss(animated: false) { continuation.resume() }
                }
            }
            window.window.isHidden = true
        }
    }

    func storedBodies() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).map(\.plainTextBody).sorted()
    }

    @Test func selectingAnEntryOpenInAnotherWindowActivatesThatWindowAndLeavesThisOneUnchanged() async throws {
        let left = try await open(), right = try await open()
        try await left.select(day: 0)
        try await right.select(day: 1)
        let rightEditor = try #require(right.openEditor)

        try await right.select(day: 0)

        #expect(left.scene.activationCount == 1)
        #expect(right.openEditor === rightEditor)
        #expect(right.secondary?.viewControllers.map { $0 === rightEditor } == [true])
        #expect(right.timeline.tableView.indexPathForSelectedRow == IndexPath(row: 0, section: 1))
        #expect(left.openEditor?.entry.id == first.id)
        await close(left, right)
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func deletingAnEntryClearsEveryOtherWindowShowingItAndDiscardsItsInput(width: UIUserInterfaceSizeClass) async throws {
        let left = try await open(width), right = try await open()
        try await left.select(day: 0)
        try left.type("Unflushed synthetic input")

        right.timeline.deleteEntry(id: first.id)
        try await left.settle()

        #expect(left.openEditor == nil)
        if width == .regular { #expect(left.showsNoEntrySelected) }
        else { #expect(left.timeline.navigationController?.topViewController === left.timeline) }
        #expect(left.root.presentedViewController == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).map(\.id) == [second.id])
        await close(left, right)
    }

    @Test func aDisconnectedWindowReleasesItsEditors() async throws {
        let left = try await open(), right = try await open()
        try await left.select(day: 0)

        left.editors.disconnect()
        try await right.select(day: 0)

        #expect(left.scene.activationCount == 0)
        #expect(right.openEditor?.entry.id == first.id)
        await close(left, right)
    }

    @Test func doneReleasesTheEntryForOtherWindows() async throws {
        let left = try await open(), right = try await open()
        try await left.select(day: 0)
        try #require(left.openEditor).finish()
        try await left.settle()

        try await right.select(day: 0)

        #expect(left.scene.activationCount == 0)
        #expect(right.openEditor?.entry.id == first.id)
        await close(left, right)
    }

    @Test func twoWindowsNeverOverwriteEachOther() async throws {
        let left = try await open(), right = try await open()
        try await left.select(day: 0)
        try left.type("Written on the left")
        try await right.select(day: 0)
        #expect(right.openEditor == nil)
        try left.type("Written on the left, then more")
        try #require(left.openEditor).finish()
        try await left.settle()

        // Opened only now, the right window starts from what the left one saved.
        try await right.select(day: 0)
        let rightEditor = try #require(right.openEditor)
        #expect(descendants(rightEditor.view, as: BlockTextView.self).first?.text == "Written on the left, then more")
        rightEditor.finish()
        try await right.settle()
        #expect(try storedBodies() == ["", "Written on the left, then more"])
        await close(left, right)
    }

    @Test func aNewEntryFollowsTheRuleOnceItAppearsInTheTimeline() async throws {
        let left = try await open(), right = try await open()
        left.timeline.createEntry()
        try await left.settle()
        let presented = try #require(left.root.presentedViewController as? UINavigationController)
        let editor = try #require(presented.topViewController as? EntryEditorViewController)
        let input = try #require(descendants(editor.view, as: BlockTextView.self).first)
        input.text = "A synthetic new entry"
        input.delegate?.textViewDidChange?(input)
        editor.flush()
        for _ in 0..<100 {
            if right.timeline.tableView.numberOfSections == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(right.timeline.tableView.numberOfSections == 3)

        try await right.select(day: 0)

        #expect(left.scene.activationCount == 1)
        #expect(right.openEditor == nil)
        #expect(right.showsNoEntrySelected)
        await close(left, right)
    }

    @Test func aPhotoImportThatFinishesAfterTheEntryWasDeletedElsewhereKeepsNothing() async throws {
        let (storage, _) = makeTemporaryPhotoStorage()
        let left = try await open(storage: storage), right = try await open(storage: storage)
        try await left.select(day: 0)
        let editor = try #require(left.openEditor)
        let photo = try storage.saveJPEG(from: makeJPEGData())
        final class PendingLoad { var continuation: CheckedContinuation<PhotoImportResult, Never>? }
        let pending = PendingLoad()
        editor.importPhotos { await withCheckedContinuation { pending.continuation = $0 } }
        for _ in 0..<100 where pending.continuation == nil { await Task.yield() }
        let load = try #require(pending.continuation)

        right.timeline.deleteEntry(id: first.id)
        try await left.settle()
        load.resume(returning: PhotoImportResult(photos: [photo], failedCount: 0))
        try await left.settle()

        #expect(left.openEditor == nil)
        #expect(presentedAlert(from: left.root) == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).map(\.id) == [second.id])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<EntryPhoto>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: storage.url(for: photo.fileName).path))
        await close(left, right)
    }
}
