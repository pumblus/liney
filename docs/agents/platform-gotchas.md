# Platform gotchas

Facts about the iOS SDK and simulators that no header, warning, or config file confesses. Each was hit in this repo; add one when a run teaches it.

## Deprecation

- An API marked `API_TO_BE_DEPRECATED` raises no compiler warning. Check the SDK header for a replacement before using an older UIKit property (for example `UIPopoverPresentationController.barButtonItem` → `sourceItem`).

## iPhone Duo simulator (iOS 27.1)

- The navigation bar is 0 pt tall: bar items sit in vertical bars. Tests that measure the bar, or assert a frame inside it, need an assertion that holds on every device.
- A popover anchored with `barButtonItem` loses its anchor on present. Anchor with `sourceItem`.
- A simulator cannot set a hinge pose, so no unit test sees an active division. Pose-dependent behaviour is checked in Device Hub (#43).

## iOS 27.1 APIs

- The deployment target is iOS 17: every 27.1 API sits behind `#available(iOS 27.1, *)`.
- `UIView.ReservedRegion` has no public initializer. Logic takes the Liney-owned `EditorFoldRule.Division`, mapped from `reservedRegions(kind: .division)`, so tests can build one.
- `reservedRegions(kind:)` returns active regions by default; code that receives divisions from elsewhere still checks `isActive`.
- No notification reports a reserved-region change. Re-query during layout and add a `UIHingeInteraction` that calls `setNeedsLayout()`.
- `UIArrangementViewController` must not sit inside a scroll view or a `UISplitViewController`; photo detail is a full-screen modal for that reason.

## Scenes and windows

- A `NSUserActivity` type opens or restores a window only when listed in `NSUserActivityTypes`. Liney lists them in the partial `Liney/Info.plist` (set as `INFOPLIST_FILE`, excluded from resources); generated keys still merge into it.
- `UIWindowScene.ActivationAction` hides itself where new windows are unavailable. Gate nothing else on `supportsMultipleScenes`.

## Tests

- `root.traitOverrides.horizontalSizeClass` on a mounted `JournalSplitViewController` drives collapse and expand; `mountInWindow(_:sizeClass:)` and `mountJournal` in `LineyTests/TestSupport.swift` set it.
