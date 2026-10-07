# Where Liney assumes device idiom, screen, or orientation

Research for pumblus/liney#19 (map #17, Liney 1.1.0 iPhone Duo support). Source: Liney sources and build settings at commit `d704376`. No app code was changed and no real journal was opened.

Duo premises used (from Apple's iPhone Duo guidance, supplied with the task, not re-verified here): the inner display ignores supported interface orientations; layout should follow size class, not idiom or orientation; `UIScreen.main` is ambiguous on two displays; the app resizes live on open/close; Split View and multiple scenes are expected; safe areas are asymmetric. Symptoms below are inferred from the code against those premises. Nothing was run on a Duo or a Duo simulator. Items marked **unverified** need a device or simulator check.

## Verdict

Liney is mostly size-driven already: there is no `UIScreen.main`, no `UIDevice` orientation read, no `viewWillTransition`, no size-class read, no fixed `UIWindow(frame:)` in the normal path, and almost all layout is Auto Layout against safe-area or layout guides. The assumptions that matter sit in three places:

1. The root hierarchy is chosen once, at scene connect, from `userInterfaceIdiom` (`LineyApp.swift:54`). It is never re-evaluated, so it cannot follow a size change.
2. Two timeline decisions read `splitViewController?.isCollapsed` at tap time (`TimelineView.swift:157`, `:168`), and the editor close path branches on the resulting hierarchy shape (`EntryEditorView.swift:261-267`).
3. App Lock state is per scene and keyed to scene activation, which has not been exercised with several visible scenes or side-by-side apps.

## Build settings and manifest

| Where | What | Duo-relevant effect |
|---|---|---|
| `Liney.xcodeproj/project.pbxproj:247,284` | `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad) | A Duo runs the iPhone slice, so everything idiom-keyed takes the iPhone branch regardless of display size. |
| `project.pbxproj:233,270` | iPhone orientations: Portrait, LandscapeLeft, LandscapeRight (no upside-down) | Honoured on the outer display. Ignored on the inner display per the premise. Nothing else in the code reads orientation. |
| `project.pbxproj:232,269` | iPad orientations: all four | Not relevant to Duo. `UIRequiresFullScreen` is unset (asserted in `LineyTests/JournalEntryFlowTests.swift:182-191`), so no full-screen opt-out exists. |
| `project.pbxproj:229,266` | `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`, no multiple-scenes key set | The built plist (DerivedData Debug simulator `Liney.app/Info.plist`, a local build artifact) contains `UIApplicationSupportsMultipleScenes = true` with empty `UISceneConfigurations`. Multiple Liney scenes are therefore already allowed; scene configuration comes only from `LineyApp.swift:25-30`. |
| `Liney/LineyApp.swift:25-30` | `configurationForConnecting` returns the same "Journal" configuration for any `session.role` | The manifest declares no external-display role, so a second-display Liney scene should not be requested. **Unverified**: confirm no extra scene or role arrives on Duo; if one did, the full journal UI would be built for it. |
| `scripts/test:38-39` | Tests run on "Liney OS27 iPhone QA" and "Liney OS27 iPad QA" only | No size-class or two-display coverage. |

## Findings by code path

### A. Device idiom and split-view collapse state

| file:line | What it does | Outer display | Inner display | Split View | Live resize |
|---|---|---|---|---|---|
| `Liney/LineyApp.swift:54-62` | `UIDevice.current.userInterfaceIdiom == .pad` picks `UISplitViewController(style: .doubleColumn)` with `.oneBesideSecondary`; otherwise a bare `UINavigationController`. Chosen once in `showRoot` from `willConnectTo`. | Navigation stack: correct (compact). | **Gap.** Duo reports the iPhone idiom, so the inner display gets a single stretched navigation stack, with no list/detail even if the window is regular width. | A phone-idiom window that Split View makes regular still has no split. | Fixed hierarchy; open/close cannot switch between stack and split. A `UISplitViewController` root collapses by size class on its own, which is the supported mechanism. |
| `Liney/TimelineView.swift:157-160`, `:168-174` | `splitViewController?.isCollapsed`: expanded replaces the secondary column; collapsed or no split pushes the editor. New entries are pushed when `isCollapsed != false`, else presented modally. | Push (nil split). | Push (nil split), so the editor fills the full inner display. | n/a for phone idiom. | Decided per tap, so correct for the state at that moment. If the window collapses with an editor open in `.secondary`, the editor leaves the visible hierarchy; the `viewWillDisappear` flush (`EntryEditorView.swift:76-82`) should save, but open-editor state and selection are lost. **Unverified**: collapse and expand with an editor open. |
| `Liney/EntryEditorView.swift:261-267` | `closeEditor` branches on `presentingViewController`, then `viewControllers.count > 1`, then `splitViewController`. | OK (pop). | OK (pop). | OK. | Reads the current hierarchy, not the original presentation. If a resize re-parents the editor between the compact stack and the secondary column, close may take the wrong branch (pop vs reset to the placeholder). **Unverified.** |
| `Liney/TimelineView.swift:122-125`, `:151-152` | Look up `splitViewController?.viewController(for: .secondary)` for an open editor (delete confirmation, `prepareForReplacement`). | nil, skipped. | nil, skipped. | OK. | While collapsed, a stale secondary editor may still be returned, so delete confirmation or replacement could target a hidden editor. Low risk, **unverified.** |
| `Liney/EntryEditorView.swift:265`, `Liney/LineyApp.swift:58-60` | Both build the "No Entry Selected" placeholder as a `.secondary` replacement. | n/a | n/a | n/a | Only reachable when a split exists. |
| `LineyTests/TimelineDeletionTests.swift:15`; `LineyTests/JournalEntryFlowTests.swift:196-198` | Tests guard or branch on `.pad` idiom and `!split.isCollapsed`. | n/a | n/a | n/a | Tests encode "phone = stack, pad = split"; they need a size-class-based variant if the root changes. |

### B. Screen, window, and fixed geometry

| file:line | What it does | Symptom |
|---|---|---|
| `Liney/AppLock.swift:137-138` | Cover window is `UIWindow(windowScene:)`; the fallback `UIWindow(frame: window.bounds)` is used only when `windowScene` is nil. | Scene-bound, so it follows each display and resizes with the scene. The fixed-frame fallback is effectively dead, but would not follow a resize or the other display. No `UIScreen.main` anywhere in `Liney/`. |
| `Liney/ExportJournalView.swift:25-28` | When no bar button is given, the share popover anchors to a 1x1 rect at the presenter's current `bounds` centre. | The only caller passes a bar button (`TimelineView.swift:181`), so this fallback is not reached. If used, the anchor goes stale on resize or fold. |
| `Liney/UIKitSupport.swift:79` | `stack.widthAnchor <= 440` (centred layout for Locked, Processing, and Message screens). | Fine on any width; a narrow centred column on a wide inner display. |
| `Liney/UIKitSupport.swift:57-59, 86-90`; `Liney/EntryEditorView.swift:48-57` | Scroll views pinned to `safeAreaLayoutGuide` leading, trailing, and top, with fixed 16/24 pt content margins; bottom is `keyboardLayoutGuide`. | Safe-area driven, so an asymmetric or hinge safe area is respected. Content is not clamped to `readableContentGuide`, so on a wide inner display (and iPad regular width) the editor body runs very long lines and a single photo spans the full width. |
| `Liney/EntryEditorView.swift:625-639`; `Liney/JournalModels.swift:425-429` | `photoGroupColumnCount` depends only on photo count, never width; a single photo is `height = width x ratio (0.5-2)`. | Reflows correctly on resize. On a wide window a single tall photo (up to 2:1) becomes taller than the display and scrolls. |
| `Liney/EntryEditorView.swift:730` | Photo detail image height is `0.6 x view.height`. | On a short, wide window (outer display landscape, half-height Split View) the image shrinks and the info and actions get less room. Content scrolls. |
| `Liney/TimelineView.swift:218-219` | 48x48 thumbnails, 3 slots. | Fixed size; fine. |
| `Liney/EntryEditorView.swift:474, 489, 592` | 44 pt minimum body height and checklist hit target; `button.frame` recomputed in `layoutSubviews`. | Recomputed on every layout, so resize is safe. |
| `Liney/EntryEditorView.swift:154-164` | `refreshVisiblePhotos()` runs in `viewDidLayoutSubviews` and on scroll, using `scroll.bounds`. | Live resize re-evaluates which photos load; handled. |

Not present in the code: `UIScreen`, `UIDevice` orientation, `interfaceOrientation`, `supportedInterfaceOrientations` overrides, `viewWillTransition`, `horizontalSizeClass` or `verticalSizeClass` reads, `preferredContentSize`, custom popover geometry.

### C. Scene lifecycle and App Lock across multiple scenes

| file:line | What it does | Symptom |
|---|---|---|
| `Liney/LineyApp.swift:36` | Each `JournalSceneDelegate` owns its own `AppLockModel`, so `isLocked`, `isSnapshotCovered`, and `isAuthenticating` are per scene; only the preference is shared via `UserDefaults` (`Liney/AppLock.swift:41-49`). | With two Liney scenes (Duo two displays, or two windows) each authenticates separately: two prompts at launch and again after returning from background. Two concurrent `LAContext` evaluations from two scenes may cancel one another, leaving that scene on the Unlock button. **Unverified.** |
| `Liney/LineyApp.swift:65-69`; `Liney/AppLock.swift:84-97` | `sceneWillResignActive` calls `protectSnapshot()`, which covers the scene with the opaque lock window whenever App Lock is enabled; `sceneDidBecomeActive` calls `unlock()`, which uncovers it. Only `sceneDidEnterBackground` sets `isLocked`. | Covering on resign-active is meant for Control Center, banners, and the Face ID sheet. If a visible but unfocused scene (Split View neighbour, or one of two displays) also receives `willResignActive`, Liney would show the lock screen while still on screen, until tapped. **Unverified**: whether an on-screen unfocused scene resigns active on iPadOS or Duo. Not reachable with App Lock off. |
| `Liney/AppLock.swift:56-69, 107-112` | Enabling App Lock in Settings sets the preference and unlocks only the calling scene's model. Other scenes' models are not notified; each reads the preference live but only re-evaluates (`onChange` -> `update()`) when its own state changes. | A second visible scene stays unlocked and uncovered after App Lock is enabled in the first, until it backgrounds or resigns active. Same on iPad multi-window today, but more visible on Duo where both scenes can be on screen at once. |
| `Liney/AppLock.swift:146-161` | `JournalPrivacyShield.update()` hides accessibility, disables interaction, and swaps key windows between the cover and the journal window, per scene. | Scene-scoped (`UIWindow(windowScene:)`, `windowLevel = .alert + 1`), so the cover follows its scene's size and display. No cross-scene interference in this code. |
| `Liney/EntryEditorView.swift:74, 94-100` | Editor flushes on `UIScene.willDeactivateNotification`, filtered to its own window scene. | Correct per scene; this is the Split View and multi-window flush already designed in (`MVP.md` "UI ownership and rollback"). An unfocused-but-visible editor saves only if its scene actually deactivates; debounced autosave (350 ms, `EntryEditorView.swift:221`) covers the rest. |
| `Liney/ImportJournalView.swift:34, 40` | Import cancels on `UIApplication.didEnterBackgroundNotification` (app-level, not scene-level). | Cancelled only when the whole app backgrounds. A scene that backgrounds while another stays foreground keeps importing. Matches "Keep Liney open"; low risk. |
| `Liney/TimelineView.swift:59`; posts at `EntryEditorView.swift:90, 234, 257` etc. | `journalDidChange` is posted on the shared `NotificationCenter` with `object` as an entry id or nil. | Cross-scene updates work (each timeline observes it). Not a layout issue. |
| `Liney/LineyApp.swift:11-22` | App-level launch work (temp-file sweep, orphan photo sweep) runs in `didFinishLaunching` with a launch timestamp. | Independent of scene count; a second scene opened later does not rerun it. |

## Expected symptom summary

| Context | Expected behaviour today |
|---|---|
| Outer display (compact portrait or landscape) | Works as on iPhone. Navigation stack, pushed editor, safe-area-pinned scrolls. |
| Inner display | Phone idiom -> bare navigation stack stretched across a wide window (`LineyApp.swift:54`). No list/detail; editor lines and single photos span the full width. Orientation lock is irrelevant. App Lock cover and sheets are fine. |
| Split View (Liney beside another app) | Layout reflows; per-scene editor flush OK. Risk is App Lock activation semantics (`LineyApp.swift:65-69`, unverified) and, if the root becomes a split, collapse handling at `TimelineView.swift:157/168` and `EntryEditorView.swift:261`. |
| Live open/close resize | Auto Layout and photo visibility reflow correctly. The root cannot change shape (`LineyApp.swift:54`). If it becomes size-driven, the editor-in-secondary versus editor-on-stack transitions (`TimelineView.swift:157`, `EntryEditorView.swift:264`) are the untested part. |
| Two scenes (one per display) | Two separate `AppLockModel`s, two Face ID prompts, no shared lock state (`LineyApp.swift:36`). |

## Interactions with product docs

- `MVP.md` "Platform and native UI" says "navigation stack on iPhone, split view on iPad". Making the root follow size class rather than idiom changes that wording, and `CLAUDE.md` requires a user-approved MVP.md update before changing product surface.
- `MVP.md` "UI ownership and rollback" already requires per-scene editor flush and native resizing, which the code does for iPad.

## Not verified here

- Behaviour on a Duo or Duo simulator (none available to this research).
- UIKit collapse/expand behaviour of an open `.secondary` editor under a live size change.
- Whether unfocused, on-screen scenes receive `willResignActive`.
- Concurrent `LAContext` behaviour across two scenes.
- `UIApplicationSupportsMultipleScenes = true` was read from a local DerivedData Debug simulator build, not regenerated.
