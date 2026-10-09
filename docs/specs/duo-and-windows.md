# iPhone Duo, Multi-Window & Adaptive Layout Specification

This specification owns screen adaptation, Split View responsiveness, iPhone Duo foldable behavior, iOS 27.1 fold avoidance, and multi-window scene coordination.

- Parent Scope: [MVP.md](../../MVP.md)
- Domain Terms: [GLOSSARY.md](../../GLOSSARY.md)
- Code Mapping: `JournalSplitView.swift`, `EntryWindow.swift`, `EntryEditorCoordinator.swift`, `WindowRestoration.swift`, `EditorFoldRule.swift`, `PhotoDetailArrangement.swift` (see [architecture.md](../agents/architecture.md))

## 1. Stories & Acceptance Criteria

- **Story 62**: Native navigation and lists follow available width: single navigation stack when compact, timeline beside open entry when regular/wide.
- **Story 63**: Support native Split View, multitasking resizing, and opening or closing iPhone Duo without losing open entry, unsaved text, or caret.
- **Story 69**: Run edge-to-edge on both iPhone Duo displays, including system Split View.
- **Story 70**: Keep entry text and photos capped at a comfortable reading column (~700 pt) in wide windows.
- **Story 71**: Keep the active typing line above the fold while iPhone Duo is partially folded with keyboard active.
- **Story 72**: On iOS 27.1+, display photo detail with photo and metadata/actions side-by-side (wide) or split across the fold (partially folded).
- **Story 73**: Continue seamlessly on outer display when iPhone Duo closes without locking.
- **Story 74**: Open an entry in its own dedicated window from timeline row context menu or row drag.
- **Story 75**: Single-editor invariant: edit each entry in at most one place app-wide; windows never overwrite each other.
- **Story 76**: Restore entry windows and selected timeline entry across app relaunch.

## 2. Implementation Decisions

### Platform Adaptation & SDK Requirements
- Built with Xcode 27.1 (iOS 27.1 SDK) for full-bleed iPhone Duo support.
- Target platform: iOS/iPadOS 17 through 27.1. iOS 27.1-only APIs are guarded with `@available(iOS 27.1, *)`.
- Layout code is strictly adaptive (geometry/size-class based): never sniff device model, idiom (`UIDevice.userInterfaceIdiom`), or orientation.
- Controls reside in navigation bars so the system can reposition them to vertical toolbars on wide displays.

### Split View & Collapsing Behavior
- Root container is `JournalSplitViewController` across all screen sizes.
- **Collapsing**: When transitioning from wide to compact width, an active editor remains on top of the navigation stack with a Back button to the timeline. If no entry was open, shows the timeline directly (never a blank secondary column).
- **Expanding**: Moves the open editor from the navigation stack into the secondary column and highlights its timeline row.
- Resizing, rotation, or folding never auto-saves or discards content on its own.

### Fold Avoidance on Foldable Displays (iOS 27.1+)
- Pure calculations in `EditorFoldRule` and system integration in `EditorFoldAvoidance`.
- When an active horizontal division (hinge) intersects the window and the software keyboard is visible, the text editing scroll area terminates at the division's top edge so the line being edited stays fully legible on the upper screen.
- Timeline, photo grids, and general scrolling lists ignore the fold and flow naturally.

### Photo Detail Adaptive Layout
- `PhotoDetailLayout` adapts presentation across screen sizes:
  - **Compact**: Stacked modal.
  - **Wide**: Side-by-side arrangement (photo leading, metadata and actions trailing).
  - **Partially folded (iOS 27.1+)**: Photo on upper screen, controls and metadata below the hinge.

### Multi-Window Coordination & Invariants
- Managed by `EntryEditorCoordinator` and `SceneEditors`:
  - **Single Editor Rule**: An entry has at most one active editor instance across all windows. Opening an entry already active in another scene brings that window to the foreground.
  - Opening an entry in a new window from a split view's secondary column flushes pending edits, clears the secondary column, and mounts the editor into the new `EntryWindow`.
  - **Entry Window UI**: Contains only that entry's editor. Done saves and closes the scene. Delete Entry confirms, deletes, and closes the scene.
  - **Privacy**: Entry window title displays the `Entry Date`, and is immediately blanked while App Lock is active.

### State Restoration
- Handled exclusively via `WindowRestoration.swift`.
- Restores windows by encoding the entry's UUID in `NSUserActivity`.
- An entry window reopens its entry or closes cleanly if the entry was deleted while suspended.
- New-entry drafts are transient and are not restored across relaunches.
