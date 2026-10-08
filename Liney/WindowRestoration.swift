import SwiftData
import UIKit

/// What a scene shows when it connects: the entry window a request or the saved restoration
/// names, otherwise a full window on the timeline.
@MainActor struct JournalWindowContent {
    let editors: SceneEditors
    let root: UIViewController
    /// Set when this scene is an entry window: one entry's editor alone.
    let entryWindow: EntryWindow?

    /// `requested` comes from Open in New Window or a dragged row; `restored` is the scene's
    /// saved state-restoration activity. An entry window whose entry is gone, or is kept by
    /// another window that is brought forward, closes, and the scene falls back to the timeline.
    init(handle: any SceneHandle, requested: some Sequence<NSUserActivity>, restored: NSUserActivity?,
         container: ModelContainer, appLock: AppLockModel, coordinator: EntryEditorCoordinator) {
        let restoration = requested.lazy.compactMap(EntryWindowActivity.entryID(of:)).first.map(WindowRestoration.entryWindow)
            ?? restored.flatMap(WindowRestoration.init)
        if case .entryWindow(let id) = restoration {
            let editors = coordinator.connectScene(handle, isEntryWindow: true)
            if let entryWindow = EntryWindow(entryID: id, container: container, appLock: appLock, editors: editors) {
                self.editors = editors
                self.entryWindow = entryWindow
                root = entryWindow.root
                return
            }
            handle.destroy()
        }
        editors = coordinator.connectScene(handle)
        entryWindow = nil
        let journal = JournalSplitViewController(
            timeline: TimelineViewController(container: container, appLock: appLock, editors: editors))
        if case .selectedEntry(let id) = restoration { journal.restoredEntryID = id }
        root = journal
    }

    /// What this window reopens after relaunch.
    var restoration: WindowRestoration? {
        if let entryWindow { return .entryWindow(entryWindow.entryID) }
        return (root as? JournalSplitViewController)?.restoration
    }
}

/// What a window reopens after relaunch. It is saved as the scene's state-restoration
/// activity, whose payload is only the entry UUID, never journal text, and the system never
/// shares it.
enum WindowRestoration: Equatable {
    /// An entry window on this entry.
    case entryWindow(UUID)
    /// A full window with this entry selected.
    case selectedEntry(UUID)

    /// Listed in `NSUserActivityTypes` beside the entry window activity.
    private static let selectedEntryType = "com.liney.app.journal"
    private static let entryIDKey = "entryID"

    /// Nil for any other activity, so the window opens on the timeline.
    init?(_ activity: NSUserActivity) {
        if let id = EntryWindowActivity.entryID(of: activity) {
            self = .entryWindow(id)
        } else if activity.activityType == Self.selectedEntryType,
                  let id = (activity.userInfo?[Self.entryIDKey] as? String).flatMap(UUID.init(uuidString:)) {
            self = .selectedEntry(id)
        } else {
            return nil
        }
    }

    var activity: NSUserActivity {
        switch self {
        case .entryWindow(let id):
            return EntryWindowActivity.make(entryID: id)
        case .selectedEntry(let id):
            let activity = NSUserActivity(activityType: Self.selectedEntryType)
            activity.userInfo = [Self.entryIDKey: id.uuidString]
            activity.isEligibleForHandoff = false
            activity.isEligibleForSearch = false
            activity.isEligibleForPrediction = false
            return activity
        }
    }
}
