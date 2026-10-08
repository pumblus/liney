import SwiftData
import UIKit

/// An entry window: one entry's editor alone. Its title in the app switcher is the Entry
/// Date, never the entry's title or text, and it shows none while App Lock is locked.
@MainActor final class EntryWindow {
    let entryID: UUID
    let editor: EntryEditorViewController
    let root: UINavigationController
    private let appLock: AppLockModel
    private let scene: any SceneHandle

    /// Takes the entry from any editor beside a timeline, saving its edits first. Nil when the
    /// entry no longer exists, or another window keeps it and has been brought forward.
    init?(entryID: UUID, container: ModelContainer, appLock: AppLockModel, editors: SceneEditors,
          storage: PhotoStorage = PhotoStorage()) {
        guard editors.coordinator.claimEntryWindow(for: entryID, in: editors) else { return nil }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == entryID })
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        self.entryID = entryID
        editor = EntryEditorViewController(entry: entry, isNew: false, context: context, storage: storage, editors: editors)
        root = UINavigationController(rootViewController: editor)
        self.appLock = appLock
        scene = editors.handle
        editor.onTitleChange = { [weak self] in self?.updateTitle() }
        appLock.addObserver(self) { [weak self] in self?.updateTitle() }
        updateTitle()
    }

    private func updateTitle() {
        scene.setTitle(appLock.isEnabled && appLock.isLocked ? nil : editor.title)
    }
}

/// The user activity that configures an entry window. Its payload is only the entry UUID,
/// never journal text, photo contents, or locations, and the system never shares it.
enum EntryWindowActivity {
    /// Listed in `NSUserActivityTypes`, so a dragged row can create a window.
    static let type = "com.liney.app.entry"
    private static let entryIDKey = "entryID"

    static func make(entryID: UUID) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        activity.userInfo = [entryIDKey: entryID.uuidString]
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        return activity
    }

    /// The entry an activity opens, or nil for any other activity.
    static func entryID(of activity: NSUserActivity) -> UUID? {
        guard activity.activityType == type else { return nil }
        return (activity.userInfo?[entryIDKey] as? String).flatMap(UUID.init(uuidString:))
    }
}
