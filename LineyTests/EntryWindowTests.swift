import SwiftData
import Testing
import UIKit
@testable import Liney

/// The user activity that configures an entry window carries only the entry UUID.
@Suite struct EntryWindowActivityTests {
    @Test func theActivityCarriesOnlyTheEntryUUID() throws {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let activity = EntryWindowActivity.make(entryID: id)

        #expect(activity.activityType == "com.liney.app.entry")
        #expect(activity.userInfo?.count == 1)
        #expect(activity.userInfo?["entryID"] as? String == "6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(activity.title == nil)
        #expect(activity.keywords.isEmpty)
        #expect(activity.webpageURL == nil)
        #expect(activity.targetContentIdentifier == nil)
        #expect(!activity.isEligibleForHandoff && !activity.isEligibleForSearch && !activity.isEligibleForPrediction)
        #expect(EntryWindowActivity.entryID(of: activity) == id)
    }

    @Test func theAppDeclaresTheActivitySoADraggedRowCanCreateAWindow() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["NSUserActivityTypes"] as? [String] == ["com.liney.app.entry"])
        let manifest = try #require(info["UIApplicationSceneManifest"] as? [String: Any])
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        #expect(info["NSFaceIDUsageDescription"] != nil)
    }

    @Test func otherActivitiesNameNoEntry() {
        let other = NSUserActivity(activityType: "com.liney.app.other")
        other.userInfo = ["entryID": UUID().uuidString]
        let malformed = NSUserActivity(activityType: "com.liney.app.entry")
        malformed.userInfo = ["entryID": "not a UUID"]
        let empty = NSUserActivity(activityType: "com.liney.app.entry")

        #expect(EntryWindowActivity.entryID(of: other) == nil)
        #expect(EntryWindowActivity.entryID(of: malformed) == nil)
        #expect(EntryWindowActivity.entryID(of: empty) == nil)
    }
}

/// Entry windows and the routing that keeps each entry in one place, with fake scene handles,
/// because a real scene request cannot run in unit tests.
@Suite(.serialized)
@MainActor
struct EntryWindowTests {
    let container: ModelContainer
    let entry: JournalEntry
    let other: JournalEntry
    let coordinator = EntryEditorCoordinator()
    let defaults: UserDefaults
    private let defaultsName = "EntryWindowTests-\(UUID().uuidString)"

    init() throws {
        container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let noon = try #require(Calendar.current.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 12)))
        entry = JournalEntry(title: "Synthetic private title", entryDate: noon)
        other = JournalEntry(title: "Synthetic other", entryDate: noon.addingTimeInterval(-86_400 * 30))
        context.insert(entry); context.insert(other)
        try context.save()
        defaults = try #require(UserDefaults(suiteName: defaultsName))
    }

    /// App Lock with its preference `enabled`, starting locked as at launch.
    func appLock(enabled: Bool = false) -> AppLockModel {
        defaults.set(enabled, forKey: "liney.requiresAppLock")
        return AppLockModel(authenticator: ApprovingAuthenticator(), defaults: defaults)
    }

    /// An entry window for `id` on a fake scene, mounted in a window.
    func openEntryWindow(_ id: UUID? = nil, appLock: AppLockModel? = nil) async throws -> (EntryWindow, FakeScene, UIWindow) {
        let scene = FakeScene()
        let editors = coordinator.connectScene(scene, isEntryWindow: true)
        let opened = try #require(EntryWindow(entryID: id ?? entry.id, container: container,
                                              appLock: appLock ?? self.appLock(), editors: editors))
        let window = try mount(opened.root)
        try await settle(window)
        return (opened, scene, window)
    }

    func mount(_ root: UIViewController, width: CGFloat = 700) throws -> UIWindow {
        let live = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: live)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
    }

    func close(_ windows: UIWindow...) async {
        for window in windows {
            if let presented = window.rootViewController?.presentedViewController {
                await withCheckedContinuation { continuation in
                    presented.dismiss(animated: false) { continuation.resume() }
                }
            }
            window.isHidden = true
        }
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
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
        try await settle(window)
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
        let timeline = TimelineViewController(container: container, appLock: appLock(),
                                              storage: makeTemporaryPhotoStorage().storage,
                                              editors: coordinator.connectScene(scene))
        let root = JournalSplitViewController(timeline: timeline)
        root.traitOverrides.horizontalSizeClass = sizeClass
        let window = try mount(root, width: 1100)
        for _ in 0..<100 where timeline.tableView.numberOfSections != 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(timeline.tableView.numberOfSections == 2)
        try await settle(window)
        return (root, scene, window)
    }

    /// Opens `entry` from the timeline of `root`.
    func select(in root: JournalSplitViewController, _ window: UIWindow) async throws -> EntryEditorViewController {
        root.timeline.tableView(root.timeline.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        try await settle(window)
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
        try type("Unsaved synthetic edit", in: source)

        let (opened, _, window) = try await openEntryWindow()
        try await settle(journalWindow)

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
        #expect(EntryWindowActivity.entryID(of: request) == other.id)
        #expect(scene.activationCount == 1)
        await close(window, journalWindow)
    }

    @Test func aSecondWindowForTheSameEntryClosesAndBringsTheFirstForward() async throws {
        let (_, scene, window) = try await openEntryWindow()

        let duplicate = EntryWindow(entryID: entry.id, container: container, appLock: appLock(),
                                    editors: coordinator.connectScene(FakeScene(), isEntryWindow: true))

        #expect(duplicate == nil)
        #expect(scene.activationCount == 1)
        await close(window)
    }

    @Test func aMissingEntryOpensNoWindow() throws {
        let editors = coordinator.connectScene(FakeScene(), isEntryWindow: true)
        #expect(EntryWindow(entryID: UUID(), container: container, appLock: appLock(), editors: editors) == nil)
    }

    @Test func rowsOfferOnlyOpenInNewWindowWhereNewWindowsAreAvailable() async throws {
        let (journal, _, window) = try await openJournalWindow()
        let table = journal.timeline.tableView!
        let row = IndexPath(row: 0, section: 0)

        let menu = journal.timeline.tableView(table, contextMenuConfigurationForRowAt: row, point: .zero)
        let items = journal.timeline.tableView(table, itemsForBeginning: FakeDragSession(), at: row)

        if UIApplication.shared.supportsMultipleScenes {
            #expect(menu != nil)
            let actions = try #require(journal.timeline.rowMenu(at: row))
            #expect(actions.children.count == 1)
            #expect(actions.children.first is UIWindowScene.ActivationAction)
            #expect(items.count == 1)
            #expect(items.first?.itemProvider.canLoadObject(ofClass: NSUserActivity.self) == true)
        } else {
            #expect(menu == nil)
            #expect(items.isEmpty)
        }
        await close(window)
    }

    func type(_ text: String, in editor: EntryEditorViewController) throws {
        let input = try #require(descendants(editor.view, as: BlockTextView.self).first)
        input.text = text
        input.delegate?.textViewDidChange?(input)
    }

    func storedEntries() throws -> [JournalEntry] {
        try ModelContext(container).fetch(FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.entryDate)]))
    }

    @Test func doneSavesThenClosesTheWindow() async throws {
        let (opened, scene, window) = try await openEntryWindow()
        try type("Synthetic window text", in: opened.editor)

        opened.editor.finish()

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
        try await settle(window)

        #expect(scene.destructionCount == 1)
        #expect(try storedEntries().map(\.id) == [other.id])
        await close(window)
    }

    @Test func theWindowTitleIsClearedWhileLocked() async throws {
        let lock = appLock(enabled: true)
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
