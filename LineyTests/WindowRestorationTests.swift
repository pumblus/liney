import SwiftData
import Testing
import UIKit
@testable import Liney

/// What a window saves for the next launch: only an entry UUID, never journal text.
@Suite struct WindowRestorationActivityTests {
    static let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    @Test(arguments: [WindowRestoration.entryWindow(id), .selectedEntry(id)])
    func theActivityCarriesOnlyTheEntryUUID(restoration: WindowRestoration) throws {
        let activity = restoration.activity

        #expect(activity.userInfo?.count == 1)
        #expect(activity.userInfo?.values.first as? String == "6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(activity.title == nil)
        #expect(activity.keywords.isEmpty)
        #expect(activity.webpageURL == nil)
        #expect(activity.targetContentIdentifier == nil)
        #expect(!activity.isEligibleForHandoff && !activity.isEligibleForSearch && !activity.isEligibleForPrediction)
        #expect(WindowRestoration(activity) == restoration)
    }

    @Test func anEntryWindowSavesTheActivityThatOpensEntryWindows() {
        let activity = WindowRestoration.entryWindow(Self.id).activity

        #expect(EntryWindowActivity.entryID(of: activity) == Self.id)
        #expect(EntryWindowActivity.entryID(of: WindowRestoration.selectedEntry(Self.id).activity) == nil)
    }

    @Test func unknownOrMalformedActivitiesRestoreNothing() {
        let other = NSUserActivity(activityType: "com.liney.app.other")
        other.userInfo = ["entryID": Self.id.uuidString]
        let malformed = WindowRestoration.selectedEntry(Self.id).activity
        malformed.userInfo = ["entryID": "not a UUID"]
        let empty = NSUserActivity(activityType: WindowRestoration.selectedEntry(Self.id).activity.activityType)

        #expect(WindowRestoration(other) == nil)
        #expect(WindowRestoration(malformed) == nil)
        #expect(WindowRestoration(empty) == nil)
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
    let defaults: UserDefaults
    private let defaultsName = "WindowRestorationTests-\(UUID().uuidString)"

    init() throws {
        container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let noon = try #require(Calendar.current.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 12)))
        entry = JournalEntry(title: "Synthetic private title", entryDate: noon)
        context.insert(entry)
        try context.save()
        defaults = try #require(UserDefaults(suiteName: defaultsName))
    }

    /// App Lock with its preference `enabled`, starting locked as at launch.
    func appLock(enabled: Bool = false) -> AppLockModel {
        defaults.set(enabled, forKey: "liney.requiresAppLock")
        return AppLockModel(authenticator: ApprovingAuthenticator(), defaults: defaults)
    }

    /// A scene connecting with `restored` as its saved state-restoration activity.
    func connect(restoring restored: NSUserActivity?, scene: FakeScene? = nil,
                 appLock: AppLockModel? = nil) -> JournalWindowContent {
        JournalWindowContent(handle: scene ?? FakeScene(), requested: [], restored: restored, container: container,
                             appLock: appLock ?? self.appLock(), coordinator: coordinator)
    }

    func mount(_ root: UIViewController, _ sizeClass: UIUserInterfaceSizeClass = .regular) async throws -> UIWindow {
        let live = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: live)
        window.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        root.traitOverrides.horizontalSizeClass = sizeClass
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        return window
    }

    func close(_ window: UIWindow) {
        window.isHidden = true
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }

    func deleteEntry() throws {
        let context = ModelContext(container)
        let id = entry.id
        for stored in try context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == id })) {
            context.delete(stored)
        }
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
    func mountJournal(_ content: JournalWindowContent, _ sizeClass: UIUserInterfaceSizeClass = .regular,
                      rows: Int = 1) async throws -> (JournalSplitViewController, UIWindow) {
        let root = try #require(content.root as? JournalSplitViewController)
        let window = try await mount(root, sizeClass)
        for _ in 0..<100 where root.timeline.tableView.numberOfSections != rows {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        return (root, window)
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func aFullWindowReopensWithItsSelectedEntry(sizeClass: UIUserInterfaceSizeClass) async throws {
        let content = connect(restoring: WindowRestoration.selectedEntry(entry.id).activity)
        let (root, window) = try await mountJournal(content, sizeClass)

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
        #expect(content.restoration == .selectedEntry(entry.id))

        editor.finish()
        try await Task.sleep(for: .milliseconds(400))
        #expect(content.restoration == nil)
        close(window)
    }

    @Test func aFullWindowWhoseSelectedEntryWasDeletedShowsTheTimelineOnly() async throws {
        try deleteEntry()
        let scene = FakeScene()

        let content = connect(restoring: WindowRestoration.selectedEntry(entry.id).activity, scene: scene)
        let (root, window) = try await mountJournal(content, rows: 0)

        #expect(root.openEditor == nil)
        #expect(content.restoration == nil)
        #expect(scene.destructionCount == 0)
        close(window)
    }

    @Test func aFullWindowWhoseSelectedEntryIsOpenInAnotherWindowRestoresOnlyTheTimeline() async throws {
        let holder = FakeScene()
        let held = connect(restoring: WindowRestoration.entryWindow(entry.id).activity, scene: holder)

        let content = connect(restoring: WindowRestoration.selectedEntry(entry.id).activity)
        let (root, window) = try await mountJournal(content)

        #expect(root.openEditor == nil)
        #expect(root.timeline.tableView.indexPathForSelectedRow == nil)
        #expect(coordinator.scene(editing: entry.id) === held.editors)
        #expect(holder.activationCount == 0)
        #expect(content.restoration == nil)
        close(window)
    }

    @Test func anUnknownActivityOpensTheTimeline() async throws {
        let unknown = NSUserActivity(activityType: "com.liney.app.retired")
        unknown.userInfo = ["entryID": entry.id.uuidString]
        let scene = FakeScene()

        let content = connect(restoring: unknown, scene: scene)
        let (root, window) = try await mountJournal(content)

        #expect(content.entryWindow == nil)
        #expect(root.openEditor == nil)
        #expect(scene.destructionCount == 0)
        #expect(content.restoration == nil)
        close(window)
    }

    @Test(arguments: [UIUserInterfaceSizeClass.regular, .compact])
    func aNewEntryIsNotRestoredAsADraft(sizeClass: UIUserInterfaceSizeClass) async throws {
        let content = connect(restoring: nil)
        let (root, window) = try await mountJournal(content, sizeClass)

        root.timeline.createEntry()
        try await Task.sleep(for: .milliseconds(400))

        if sizeClass == .compact { #expect(root.openEditor?.isNew == true) }
        #expect(content.restoration == nil)
        if let presented = root.presentedViewController {
            await withCheckedContinuation { continuation in presented.dismiss(animated: false) { continuation.resume() } }
        }
        close(window)
    }

    @Test func restoredWindowsFollowTheAppWideLock() async throws {
        let lock = appLock(enabled: true)
        let lockScene = lock.connectScene()
        let scene = FakeScene()

        let content = connect(restoring: WindowRestoration.entryWindow(entry.id).activity, scene: scene, appLock: lock)
        let window = try await mount(content.root)

        #expect(lockScene.hidesJournalContent)
        #expect(scene.title == nil)
        await lockScene.didBecomeActive()
        #expect(!lockScene.hidesJournalContent)
        #expect(scene.title?.contains("2023") == true)
        withExtendedLifetime(content) { }  // The scene delegate keeps its content.
        close(window)
    }
}
