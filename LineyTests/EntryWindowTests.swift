import SwiftData
import Testing
import UIKit
@testable import Liney

/// Entry windows and the routing that keeps each entry in one place, with fake scene handles,
/// because a real scene request cannot run in unit tests.
@Suite(.serialized)
@MainActor
struct EntryWindowTests {
    let container: ModelContainer
    let entry: JournalEntry
    let other: JournalEntry
    let coordinator = EntryEditorCoordinator()
    let preferences = PreferenceSuite()

    init() throws {
        container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let noon = try #require(Calendar.current.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 12)))
        entry = JournalEntry(title: "Synthetic private title", entryDate: noon)
        other = JournalEntry(title: "Synthetic other", entryDate: noon.addingTimeInterval(-86_400 * 30))
        context.insert(entry); context.insert(other)
        try context.save()
    }

    /// An entry window for `id` on a fake scene, mounted in a window.
    func openEntryWindow(_ id: UUID? = nil, appLock: AppLockModel? = nil) async throws -> (EntryWindow, FakeScene, UIWindow) {
        let scene = FakeScene()
        let editors = coordinator.connectScene(scene, isEntryWindow: true)
        let opened = try #require(EntryWindow(entryID: id ?? entry.id, container: container,
                                              appLock: appLock ?? preferences.makeLock(), editors: editors))
        let window = try mountInWindow(opened.root, width: 700)
        try await waitForLayout(window)
        return (opened, scene, window)
    }

    func close(_ windows: UIWindow...) async {
        for window in windows { await unmount(window) }
        preferences.remove()
    }

    @Test func anEntryWindowHoldsOnlyThatEntrysEditorTitledWithItsEntryDate() async throws {
        let (opened, scene, window) = try await openEntryWindow()

        let navigation = try #require(opened.root as? UINavigationController)
        #expect(navigation.viewControllers.count == 1)
        let editor = try #require(navigation.topViewController as? EntryEditorViewController)
        #expect(editor.entry.id == entry.id)
        let title = try #require(scene.title)
        #expect(title == editor.title)
        #expect(title.contains("2023") && title.contains("15"))
        #expect(!title.contains("Synthetic"))
        await close(window)
    }

    @Test func theWindowTitleFollowsTheEntryDate() async throws {
        let (opened, scene, window) = try await openEntryWindow()
        let editor = opened.editor
        let dateButton = try #require(descendants(editor.view, as: UIButton.self)
            .first { $0.accessibilityLabel == String(localized: "Edit Entry Date") })
        dateButton.sendActions(for: .touchUpInside)
        try await waitForLayout(window)
        let sheet = try #require((editor.presentedViewController as? UINavigationController)?.topViewController)
        let picker = try #require(descendants(sheet.view, as: UIDatePicker.self).first)

        picker.date = try #require(Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 9, hour: 12)))
        picker.sendActions(for: .valueChanged)

        #expect(scene.title?.contains("2024") == true)
        #expect(scene.title?.contains("9") == true)
        await close(window)
    }

    /// A full window (timeline and secondary column) on a fake scene, listing both entries.
    func openJournalWindow(_ sizeClass: UIUserInterfaceSizeClass = .regular) async throws -> (JournalSplitViewController, FakeScene, UIWindow) {
        let scene = FakeScene()
        let (root, window) = try await mountJournal(container, days: 2, sizeClass: sizeClass, appLock: preferences.makeLock(),
                                                    editors: coordinator.connectScene(scene))
        return (root, scene, window)
    }

    /// Opens `entry` from the timeline of `root`.
    func select(in root: JournalSplitViewController, _ window: UIWindow) async throws -> EntryEditorViewController {
        root.timeline.tableView(root.timeline.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        try await waitForLayout(window)
        return try #require(root.openEditor)
    }

    @Test func deletingTheEntryElsewhereClosesItsWindow() async throws {
        let (_, scene, window) = try await openEntryWindow()
        let (journal, _, journalWindow) = try await openJournalWindow()

        journal.timeline.deleteEntry(id: entry.id)

        #expect(scene.destructionCount == 1)
        await close(window, journalWindow)
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func openingAnEntryShownBesideATimelineMovesItWithItsEdits(width: UIUserInterfaceSizeClass) async throws {
        let (journal, journalScene, journalWindow) = try await openJournalWindow(width)
        let source = try await select(in: journal, journalWindow)
        try typeInFirstBlock("Unsaved synthetic edit", of: source)

        let (opened, _, window) = try await openEntryWindow()
        try await waitForLayout(journalWindow)

        #expect(journal.openEditor == nil)
        if width == .regular {
            let secondary = journal.viewController(for: .secondary) as? UINavigationController
            #expect(secondary?.topViewController?.title == String(localized: "No Entry Selected"))
        } else {
            #expect(journal.timeline.navigationController?.topViewController === journal.timeline)
        }
        #expect(descendants(opened.editor.view, as: BlockTextView.self).first?.text == "Unsaved synthetic edit")
        #expect(try storedEntries().last?.plainTextBody == "Unsaved synthetic edit")
        #expect(coordinator.scene(editing: entry.id)?.isEntryWindow == true)
        #expect(journalScene.activationCount == 0)
        await close(window, journalWindow)
    }

    @Test func openInNewWindowOnAnEntryInItsOwnWindowBringsThatWindowForward() async throws {
        let (_, scene, window) = try await openEntryWindow()
        let (journal, _, journalWindow) = try await openJournalWindow()
        let editors = try #require(journal.timeline.editors)

        #expect(editors.newWindowActivity(for: entry.id) == nil)
        #expect(scene.activationCount == 1)
        let request = try #require(editors.newWindowActivity(for: other.id))
        #expect(WindowRestoration(request) == .entryWindow(other.id))
        #expect(scene.activationCount == 1)
        await close(window, journalWindow)
    }

    @Test func aSecondWindowForTheSameEntryClosesAndBringsTheFirstForward() async throws {
        let (_, scene, window) = try await openEntryWindow()

        let duplicate = EntryWindow(entryID: entry.id, container: container, appLock: preferences.makeLock(),
                                    editors: coordinator.connectScene(FakeScene(), isEntryWindow: true))

        #expect(duplicate == nil)
        #expect(scene.activationCount == 1)
        await close(window)
    }

    @Test func aMissingEntryOpensNoWindow() throws {
        let editors = coordinator.connectScene(FakeScene(), isEntryWindow: true)
        #expect(EntryWindow(entryID: UUID(), container: container, appLock: preferences.makeLock(), editors: editors) == nil)
    }

    /// The system hides Open in New Window and ignores a dragged row where new windows are
    /// unavailable, so every device offers them.
    @Test func rowsOfferOnlyTheSystemOpenInNewWindowAndDragOutAnEntryWindowActivity() async throws {
        let (journal, _, window) = try await openJournalWindow()
        let table = journal.timeline.tableView!
        let row = IndexPath(row: 0, section: 0)

        let menu = journal.timeline.tableView(table, contextMenuConfigurationForRowAt: row, point: .zero)
        let items = journal.timeline.tableView(table, itemsForBeginning: FakeDragSession(), at: row)

        #expect(menu != nil)
        let actions = try #require(journal.timeline.rowMenu(at: row))
        #expect(actions.children.count == 1)
        #expect(actions.children.first is UIWindowScene.ActivationAction)
        #expect(items.count == 1)
        #expect(items.first?.itemProvider.canLoadObject(ofClass: NSUserActivity.self) == true)
        await close(window)
    }

    /// A screen an editor shows over its entry.
    enum Presentation: CaseIterable { case entryDate, photoDetail, deleteConfirmation }

    func present(_ presentation: Presentation, from editor: EntryEditorViewController, in window: UIWindow) async throws {
        switch presentation {
        case .entryDate:
            try #require(descendants(editor.view, as: UIButton.self)
                .first { $0.accessibilityLabel == String(localized: "Edit Entry Date") }).sendActions(for: .touchUpInside)
        case .photoDetail:
            let group = try #require(descendants(editor.view, as: PhotoGroupView.self).first)
            try #require(descendants(group, as: UIButton.self).first).sendActions(for: .touchUpInside)
        case .deleteConfirmation:
            editor.confirmDeleteEntry()
        }
        try await waitForLayout(window)
        try #require(editor.presentedViewController != nil)
    }

    @Test(arguments: Presentation.allCases)
    func deletingTheEntryElsewhereClosesWhatIsShownOverIt(presentation: Presentation) async throws {
        let context = ModelContext(container)
        for stored in try context.fetch(FetchDescriptor<JournalEntry>()) {
            _ = stored.insertPhotoGroup(fileNames: ["synthetic-missing.jpg"], in: context)
        }
        try context.save()
        let (shown, _, shownWindow) = try await openJournalWindow()
        let (opened, scene, window) = try await openEntryWindow(other.id)
        let besideTimeline = try await select(in: shown, shownWindow)
        try await present(presentation, from: besideTimeline, in: shownWindow)
        try await present(presentation, from: opened.editor, in: window)
        let (deleting, _, deletingWindow) = try await openJournalWindow()

        deleting.timeline.deleteEntry(id: entry.id)
        deleting.timeline.deleteEntry(id: other.id)
        try await waitForLayout(shownWindow)

        #expect(shown.presentedViewController == nil)
        #expect(shown.openEditor == nil)
        #expect(opened.root.presentedViewController == nil)
        #expect(scene.destructionCount == 1)
        #expect(try storedEntries().isEmpty)
        await close(shownWindow, window, deletingWindow)
    }

    func storedEntries() throws -> [JournalEntry] {
        try ModelContext(container).fetch(FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.entryDate)]))
    }

    @Test func doneSavesThenClosesTheWindow() async throws {
        let (opened, scene, window) = try await openEntryWindow()
        try typeInFirstBlock("Synthetic window text", of: opened.editor)

        try tapDone(in: opened.editor)

        #expect(scene.destructionCount == 1)
        #expect(try storedEntries().last?.plainTextBody == "Synthetic window text")
        await close(window)
    }

    @Test func deleteEntryConfirmsDeletesThenClosesTheWindow() async throws {
        let (opened, scene, window) = try await openEntryWindow()

        opened.editor.confirmDeleteEntry()
        let confirmation = try await waitForAlert(from: opened.root)
        #expect(scene.destructionCount == 0)
        try await perform(String(localized: "Delete Entry"), in: confirmation)
        try await waitForLayout(window)

        #expect(scene.destructionCount == 1)
        #expect(try storedEntries().map(\.id) == [other.id])
        await close(window)
    }

    @Test func theWindowTitleIsClearedWhileLocked() async throws {
        let lock = preferences.makeLock(enabled: true)
        let (opened, scene, window) = try await openEntryWindow(appLock: lock)
        #expect(scene.title == nil)

        await lock.unlock()
        let unlocked = scene.title
        lock.connectScene().didEnterBackground()

        #expect(unlocked?.contains("2023") == true)
        #expect(scene.title == nil)
        withExtendedLifetime(opened) { }  // The scene delegate keeps its entry window.
        await close(window)
    }
}

/// Stands in for the drag the system starts when a row is lifted.
private final class FakeDragSession: NSObject, UIDragSession {
    var localContext: Any?
    var items: [UIDragItem] = []
    var allowsMoveOperation: Bool { false }
    var isRestrictedToDraggingApplication: Bool { false }
    func location(in view: UIView) -> CGPoint { .zero }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { false }
}
