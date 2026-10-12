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
        let restoration = requested.lazy.compactMap(WindowRestoration.entryWindowID(of:)).first.map(WindowRestoration.entryWindow)
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
        if case .fullWindow(let mode, let id) = restoration {
            journal.timeline.setMode(mode)
            journal.restoredEntryID = id
        }
        root = journal
    }

    /// What this window reopens after relaunch.
    var restoration: WindowRestoration? {
        if let entryWindow { return .entryWindow(entryWindow.entryID) }
        return (root as? JournalSplitViewController)?.restoration
    }
}

/// What a window opens: an entry window, or a full window in its timeline mode with an entry
/// selected or none. Its user activity is saved as the scene's state-restoration activity, and an
/// entry window's activity also requests a new window from Open in New Window or a dragged row.
/// The payload is only the mode and an entry UUID, never journal text, photo contents, or
/// locations, and the system never shares it.
enum WindowRestoration: Equatable {
    /// An entry window on this entry.
    case entryWindow(UUID)
    /// A full window showing the timeline in `mode`, with `selectedEntry` open.
    case fullWindow(mode: TimelineViewController.Mode, selectedEntry: UUID?)

    /// Both listed in `NSUserActivityTypes`, so a dragged row can create a window and windows restore.
    private static let entryWindowType = "com.liney.app.entry"
    private static let fullWindowType = "com.liney.app.journal"
    private static let entryIDKey = "entryID"
    /// Present only for Calendar; activities saved before the mode existed open in List.
    private static let modeKey = "mode"
    private static let calendarMode = "calendar"

    /// Nil for any other activity, so the window opens on the timeline in List.
    init?(_ activity: NSUserActivity) {
        let entryID = activity.userInfo?[Self.entryIDKey]
        let id = (entryID as? String).flatMap(UUID.init(uuidString:))
        guard entryID == nil || id != nil else { return nil }
        switch activity.activityType {
        case Self.entryWindowType:
            guard let id else { return nil }
            self = .entryWindow(id)
        case Self.fullWindowType:
            let mode: TimelineViewController.Mode = activity.userInfo?[Self.modeKey] as? String == Self.calendarMode ? .calendar : .list
            guard id != nil || mode == .calendar else { return nil }
            self = .fullWindow(mode: mode, selectedEntry: id)
        default: return nil
        }
    }

    var activity: NSUserActivity {
        let activity: NSUserActivity
        switch self {
        case .entryWindow(let id):
            activity = NSUserActivity(activityType: Self.entryWindowType)
            activity.userInfo = [Self.entryIDKey: id.uuidString]
        case .fullWindow(let mode, let id):
            activity = NSUserActivity(activityType: Self.fullWindowType)
            var userInfo: [String: String] = [:]
            if let id { userInfo[Self.entryIDKey] = id.uuidString }
            if mode == .calendar { userInfo[Self.modeKey] = Self.calendarMode }
            activity.userInfo = userInfo
        }
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        return activity
    }

    /// The entry an entry-window activity opens, or nil for any other activity.
    static func entryWindowID(of activity: NSUserActivity) -> UUID? {
        guard case .entryWindow(let id) = WindowRestoration(activity) else { return nil }
        return id
    }
}
