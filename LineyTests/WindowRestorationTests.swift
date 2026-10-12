import SwiftData
import Testing
import UIKit
@testable import Liney

/// What a window saves for the next launch, and what requests an entry window: only the
/// timeline mode and an entry UUID, never journal text.
@Suite struct WindowRestorationActivityTests {
    static let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    static let selected = WindowRestoration.fullWindow(mode: .list, selectedEntry: id)

    @Test(arguments: [WindowRestoration.entryWindow(id), selected])
    func theActivityCarriesOnlyTheEntryUUID(restoration: WindowRestoration) throws {
        let activity = restoration.activity

        #expect(activity.userInfo?.count == 1)
        #expect(activity.userInfo?["entryID"] as? String == "6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(activity.title == nil)
        #expect(activity.keywords.isEmpty)
        #expect(activity.webpageURL == nil)
        #expect(activity.targetContentIdentifier == nil)
        #expect(!activity.isEligibleForHandoff && !activity.isEligibleForSearch && !activity.isEligibleForPrediction)
        #expect(WindowRestoration(activity) == restoration)
    }

    @Test func anEntryWindowSavesTheActivityThatOpensEntryWindows() {
        let activity = WindowRestoration.entryWindow(Self.id).activity

        #expect(activity.activityType == "com.liney.app.entry")
        #expect(WindowRestoration.entryWindowID(of: activity) == Self.id)
        #expect(Self.selected.activity.activityType == "com.liney.app.journal")
        #expect(WindowRestoration.entryWindowID(of: Self.selected.activity) == nil)
    }

    @Test(arguments: [nil, id])
    func aCalendarWindowsActivityCarriesOnlyTheModeAndTheEntryUUID(selectedEntry: UUID?) {
        let restoration = WindowRestoration.fullWindow(mode: .calendar, selectedEntry: selectedEntry)
        let activity = restoration.activity

        #expect(activity.activityType == "com.liney.app.journal")
        #expect(activity.userInfo?.count == (selectedEntry == nil ? 1 : 2))
        #expect(activity.userInfo?["mode"] as? String == "calendar")
        #expect(activity.userInfo?["entryID"] as? String == selectedEntry?.uuidString)
        #expect(activity.title == nil && activity.keywords.isEmpty && activity.webpageURL == nil)
        #expect(!activity.isEligibleForHandoff && !activity.isEligibleForSearch && !activity.isEligibleForPrediction)
        #expect(WindowRestoration(activity) == restoration)
        #expect(WindowRestoration.entryWindowID(of: activity) == nil)
    }

    @Test func anActivitySavedBeforeCalendarModeRestoresList() {
        let saved = NSUserActivity(activityType: "com.liney.app.journal")
        saved.userInfo = ["entryID": Self.id.uuidString]

        #expect(WindowRestoration(saved) == .fullWindow(mode: .list, selectedEntry: Self.id))
    }

    @Test func theAppDeclaresItsActivitiesSoADraggedRowCanCreateAWindowAndWindowsRestore() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["NSUserActivityTypes"] as? [String] == ["com.liney.app.entry", "com.liney.app.journal"])
        let manifest = try #require(info["UIApplicationSceneManifest"] as? [String: Any])
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        #expect(info["NSFaceIDUsageDescription"] != nil)
    }

    @Test(arguments: [WindowRestoration.entryWindow(id), selected])
    func unknownOrMalformedActivitiesRestoreNothing(restoration: WindowRestoration) {
        let other = NSUserActivity(activityType: "com.liney.app.other")
        other.userInfo = ["entryID": Self.id.uuidString]
        let malformed = restoration.activity
        malformed.userInfo = ["entryID": "not a UUID"]
        let empty = NSUserActivity(activityType: restoration.activity.activityType)

        #expect(WindowRestoration(other) == nil)
        #expect(WindowRestoration(malformed) == nil)
        #expect(WindowRestoration(empty) == nil)
        #expect(WindowRestoration.entryWindowID(of: malformed) == nil)
    }
}

/// Windows reopened after relaunch, with fake scene handles, because a real scene cannot
/// connect in unit tests.
@Suite(.serialized)
@MainActor
struct WindowRestorationTests {
    let container: ModelContainer
    let entry: JournalEntry
    let coordinator = EntryEditorCoordinator()
    let preferences = PreferenceSuite()

    init() throws {
        container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let noon = try #require(Calendar.current.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 12)))
        entry = JournalEntry(title: "Synthetic private title", entryDate: noon)
        context.insert(entry)
        try context.save()
    }

    /// A scene connecting with `restored` as its saved state-restoration activity.
    func connect(restoring restored: NSUserActivity?, scene: FakeScene? = nil,
                 appLock: AppLockModel? = nil) -> JournalWindowContent {
        JournalWindowContent(handle: scene ?? FakeScene(), requested: [], restored: restored, container: container,
                             appLock: appLock ?? preferences.makeLock(), coordinator: coordinator)
    }

    func close(_ window: UIWindow) async {
        await unmount(window)
        preferences.remove()
    }

    func deleteEntry() throws {
        let context = ModelContext(container)
        if let stored = try context.entry(id: entry.id) { context.delete(stored) }
        try context.save()
    }

    @Test func anEntryWindowReopensItsEntry() async throws {
        let scene = FakeScene()
        let content = connect(restoring: WindowRestoration.entryWindow(entry.id).activity, scene: scene)

        let entryWindow = try #require(content.entryWindow)
        #expect(entryWindow.editor.entry.id == entry.id)
        #expect(content.root === entryWindow.root)
        #expect(content.editors.isEntryWindow)
        #expect(coordinator.scene(editing: entry.id) === content.editors)
        #expect(scene.destructionCount == 0)
        #expect(content.restoration == .entryWindow(entry.id))
    }

    @Test func anEntryWindowWhoseEntryWasDeletedCloses() async throws {
        try deleteEntry()
        let scene = FakeScene()

        let content = connect(restoring: WindowRestoration.entryWindow(entry.id).activity, scene: scene)

        #expect(content.entryWindow == nil)
        #expect(scene.destructionCount == 1)
        #expect(content.root is JournalSplitViewController)
        #expect(!content.editors.isEntryWindow)
    }

    /// The full window `content` shows, mounted, once its timeline lists the entries.
    func mountJournalRoot(of content: JournalWindowContent, _ sizeClass: UIUserInterfaceSizeClass = .regular,
                          rows: Int = 1) async throws -> (JournalSplitViewController, UIWindow) {
        let root = try #require(content.root as? JournalSplitViewController)
        let window = try mountInWindow(root, sizeClass: sizeClass)
        try await waitForLayout(window)
        try await waitUntil { root.timeline.tableView.numberOfSections == rows }
        try await Task.sleep(for: .milliseconds(100))
        return (root, window)
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func aFullWindowReopensWithItsSelectedEntry(sizeClass: UIUserInterfaceSizeClass) async throws {
        let content = connect(restoring: WindowRestoration.fullWindow(mode: .list, selectedEntry: entry.id).activity)
        let (root, window) = try await mountJournalRoot(of: content, sizeClass)

        let editor = try #require(root.openEditor)
        #expect(editor.entry.id == entry.id)
        #expect(!editor.isNew)
        if sizeClass == .compact {
            #expect(root.timeline.navigationController?.viewControllers == [root.timeline, editor])
        } else {
            #expect((root.viewController(for: .secondary) as? UINavigationController)?.viewControllers == [editor])
            #expect(root.timeline.tableView.indexPathForSelectedRow == IndexPath(row: 0, section: 0))
        }
        #expect(coordinator.scene(editing: entry.id) === content.editors)
        #expect(content.restoration == .fullWindow(mode: .list, selectedEntry: entry.id))

        try tapDone(in: editor)
        try await Task.sleep(for: .milliseconds(400))
        #expect(content.restoration == nil)
        await close(window)
    }

    /// Waits until `timeline`'s Calendar View shows its months.
    func waitForCalendar(in timeline: TimelineViewController) async throws -> CalendarViewController {
        let calendarView = try #require(timeline.calendarView)
        try await waitUntil { !calendarView.view.isHidden && calendarView.collectionView.numberOfSections > 0 }
        return calendarView
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func aFullWindowInCalendarModeReopensInCalendarMode(sizeClass: UIUserInterfaceSizeClass) async throws {
        let content = connect(restoring: WindowRestoration.fullWindow(mode: .calendar, selectedEntry: nil).activity)
        let (root, window) = try await mountJournalRoot(of: content, sizeClass, rows: 0)

        let calendarView = try await waitForCalendar(in: root.timeline)
        #expect(root.timeline.mode == .calendar)
        #expect(calendarView.view.window != nil && !calendarView.view.isHidden)
        #expect((root.timeline.navigationItem.titleView as? UISegmentedControl)?.selectedSegmentIndex == 1)
        #expect(root.timeline.navigationItem.searchController == nil)
        #expect(root.openEditor == nil)
        #expect(content.restoration == .fullWindow(mode: .calendar, selectedEntry: nil))

        root.timeline.setMode(.list)
        #expect(content.restoration == nil)
        await close(window)
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func aFullWindowInCalendarModeReopensWithItsSelectedEntry(sizeClass: UIUserInterfaceSizeClass) async throws {
        let content = connect(restoring: WindowRestoration.fullWindow(mode: .calendar, selectedEntry: entry.id).activity)
        let (root, window) = try await mountJournalRoot(of: content, sizeClass, rows: 0)

        _ = try await waitForCalendar(in: root.timeline)
        #expect(root.timeline.mode == .calendar)
        let editor = try #require(root.openEditor)
        #expect(editor.entry.id == entry.id)
        #expect(content.restoration == .fullWindow(mode: .calendar, selectedEntry: entry.id))

        try tapDone(in: editor)
        try await Task.sleep(for: .milliseconds(400))
        #expect(content.restoration == .fullWindow(mode: .calendar, selectedEntry: nil))
        await close(window)
    }

    @Test func choosingCalendarIsSavedForTheNextLaunch() async throws {
        let content = connect(restoring: nil)
        let (root, window) = try await mountJournalRoot(of: content)
        #expect(root.timeline.mode == .list)
        #expect(content.restoration == nil)

        root.timeline.setMode(.calendar)

        #expect(content.restoration == .fullWindow(mode: .calendar, selectedEntry: nil))
        await close(window)
    }

    @Test func anActivitySavedBeforeCalendarModeReopensInList() async throws {
        let saved = NSUserActivity(activityType: "com.liney.app.journal")
        saved.userInfo = ["entryID": entry.id.uuidString]

        let content = connect(restoring: saved)
        let (root, window) = try await mountJournalRoot(of: content)

        #expect(root.timeline.mode == .list)
        #expect(root.timeline.navigationItem.searchController != nil)
        #expect(root.openEditor?.entry.id == entry.id)
        await close(window)
    }

    @Test func aFullWindowWhoseSelectedEntryWasDeletedShowsTheTimelineOnly() async throws {
        try deleteEntry()
        let scene = FakeScene()

        let content = connect(restoring: WindowRestoration.fullWindow(mode: .list, selectedEntry: entry.id).activity, scene: scene)
        let (root, window) = try await mountJournalRoot(of: content, rows: 0)

        #expect(root.openEditor == nil)
        #expect(content.restoration == nil)
        #expect(scene.destructionCount == 0)
        await close(window)
    }

    @Test func aFullWindowWhoseSelectedEntryIsOpenInAnotherWindowRestoresOnlyTheTimeline() async throws {
        let holder = FakeScene()
        let held = connect(restoring: WindowRestoration.entryWindow(entry.id).activity, scene: holder)

        let content = connect(restoring: WindowRestoration.fullWindow(mode: .list, selectedEntry: entry.id).activity)
        let (root, window) = try await mountJournalRoot(of: content)

        #expect(root.openEditor == nil)
        #expect(root.timeline.tableView.indexPathForSelectedRow == nil)
        #expect(coordinator.scene(editing: entry.id) === held.editors)
        #expect(holder.activationCount == 0)
        #expect(content.restoration == nil)
        await close(window)
    }

    @Test func anUnknownActivityOpensTheTimeline() async throws {
        let unknown = NSUserActivity(activityType: "com.liney.app.retired")
        unknown.userInfo = ["entryID": entry.id.uuidString]
        let scene = FakeScene()

        let content = connect(restoring: unknown, scene: scene)
        let (root, window) = try await mountJournalRoot(of: content)

        #expect(content.entryWindow == nil)
        #expect(root.openEditor == nil)
        #expect(scene.destructionCount == 0)
        #expect(content.restoration == nil)
        await close(window)
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func aNewEntryIsNotRestoredAsADraft(sizeClass: UIUserInterfaceSizeClass) async throws {
        let content = connect(restoring: nil)
        let (root, window) = try await mountJournalRoot(of: content, sizeClass)

        try tapNewEntry(in: root.timeline)
        try await Task.sleep(for: .milliseconds(400))

        if sizeClass == .compact { #expect(root.openEditor?.isNew == true) }
        #expect(content.restoration == nil)
        if let presented = root.presentedViewController {
            await withCheckedContinuation { continuation in presented.dismiss(animated: false) { continuation.resume() } }
        }
        await close(window)
    }

    @Test func restoredWindowsFollowTheAppWideLock() async throws {
        let lock = preferences.makeLock(enabled: true)
        let lockScene = lock.connectScene()
        let scene = FakeScene()

        let content = connect(restoring: WindowRestoration.entryWindow(entry.id).activity, scene: scene, appLock: lock)
        let window = try mountInWindow(content.root)
        try await waitForLayout(window)

        #expect(lockScene.hidesJournalContent)
        #expect(scene.title == nil)
        await lockScene.didBecomeActive()
        #expect(!lockScene.hidesJournalContent)
        #expect(scene.title?.contains("2023") == true)
        withExtendedLifetime(content) { }  // The scene delegate keeps its content.
        await close(window)
    }
}
