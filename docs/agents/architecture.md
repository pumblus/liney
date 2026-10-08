# Architecture map

Where each responsibility lives in `Liney/`. Product decisions and their reasons live in [MVP.md](../../MVP.md) under Implementation Decisions; this map only says which file carries them. Named by file and type, so it stays true while line numbers move.

## Scene composition

A scene connects in `JournalSceneDelegate` (`LineyApp.swift`):

```text
JournalSceneDelegate.scene(_:willConnectTo:)
  AppLockModel.connectScene()            -> AppLockScene, then JournalPrivacyShield
  JournalWindowContent(...)              WindowRestoration.swift
    entry window requested or restored   -> EntryWindow (one editor, nothing else)
    otherwise                            -> JournalSplitViewController (timeline + entry)
  window.rootViewController = content.root
```

`LineyApp` owns the app-wide singletons every scene shares: the `ModelContainer`, `AppLockModel`, and `EntryEditorCoordinator`.

## Files

| File | Owns |
|---|---|
| `LineyApp.swift` | App delegate, launch sweeps, the scene delegate and its lifecycle forwarding |
| `JournalSplitView.swift` | `JournalSplitViewController`: the root of every full window; routing (`showEntry`, `showNewEntry`, `closeEntry`) and moving the same editor across collapse and expand |
| `TimelineView.swift` | `TimelineViewController`: timeline, search, row menu with Open in New Window, row drag |
| `TimelineRepository.swift` | `TimelineRepository` actor: timeline and search queries off the main actor |
| `EntryEditorView.swift` | `EntryEditorViewController` (autosave, flush, close), `BlockTextView`, `PhotoGroupView`, `EntryDateViewController`, `PhotoDetailViewController` |
| `EntryEditorCoordinator.swift` | `EntryEditorCoordinator` (one editor per entry, app-wide), `SceneEditors` (one scene's editors; callers use only its surface), `SceneHandle` |
| `EntryWindow.swift` | `EntryWindow`: an entry window's root and its Entry Date title |
| `WindowRestoration.swift` | `JournalWindowContent` (what a connecting scene shows) and `WindowRestoration`, the only entry-UUID `NSUserActivity` codec |
| `AppLock.swift` | `AppLockModel` (app-wide lock state), `AppLockScene` (per-scene snapshot cover), `JournalPrivacyShield`, `LockedJournalController` |
| `EditorFoldRule.swift` | `EditorFoldRule` (pure calculation) and `EditorFoldAvoidance` (reads divisions and the keyboard on iOS 27.1) |
| `PhotoDetailArrangement.swift` | `PhotoDetailLayout` (stacked, sideBySide, aroundFold) and the iOS 27.1 split arrangement |
| `JournalModels.swift` | SwiftData models and domain operations; `ModelContext.entry(id:)` |
| `PhotoStorage.swift` | Copied photo files, compression, orphan sweep |
| `DayOneImport.swift`, `ImportJournalView.swift` | Day One Import |
| `JournalExport.swift`, `ExportJournalView.swift` | Markdown Export and its share sheet |
| `SettingsViewController.swift` | Settings |
| `UIKitSupport.swift` | Shared UIKit helpers, alerts, `StoredPhotoView` |

## Tests

`LineyTests/` holds one suite file per area, named after the type or flow it covers (`JournalSplitViewTests`, `EntryWindowTests`, `AppLockTests`, ...). Shared fixtures live in `LineyTests/TestSupport.swift`; read it before writing a mount, wait, or typing helper.

Platform behaviour that only shows up at runtime is in [platform-gotchas.md](platform-gotchas.md).
