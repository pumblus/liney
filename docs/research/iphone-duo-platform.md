# iPhone Duo: what it requires and offers a UIKit app

Research for pumblus/liney#18 (map #17, "Liney 1.1.0: iPhone Duo support"). Researched 2026-10-07 against Apple primary sources only. Apple's beta and RC material is moving: re-check anything marked "unconfirmed" before building on it.

## Gist

An iPhone Duo is still an iPhone (`.phone` idiom, scene lifecycle, size classes). Existing apps run unchanged, but only a rebuild with Xcode 27.1 / the iOS 27.1 SDK makes the app edge-to-edge with system bars moved to the side. The cost for a UIKit app is: use size classes and safe areas (never screen, idiom or orientation), keep bars on UINavigationController / UITabBarController, and test in Device Hub. Everything Duo-specific (reserved regions, hinge, vertical bars, arrangement views, camera accessory) is new in iOS 27.1 and optional, so it needs `#available(iOS 27.1, *)` gating against Liney's iOS 17 deployment target.

## Sources

| Short name | Link |
| --- | --- |
| Landing page | <https://developer.apple.com/iphone-duo/> |
| Prepare checklist | <https://developer.apple.com/iphone-duo/prepare/> |
| T1 Prepare (111461) | <https://developer.apple.com/videos/play/tech-talks/111461/> |
| T2 Raise the bar (111462) | <https://developer.apple.com/videos/play/tech-talks/111462/> |
| T3 Strike a pose (111463) | <https://developer.apple.com/videos/play/tech-talks/111463/> |
| T4 Multiple displays and scenes (111464) | <https://developer.apple.com/videos/play/tech-talks/111464/> |
| T5 Camera (111465) | <https://developer.apple.com/videos/play/tech-talks/111465/> |
| T6 Design (111466) | <https://developer.apple.com/videos/play/tech-talks/111466/> |
| HIG | <https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo> |
| Doc: Preparing your app | <https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo> |
| WWDC26 278, Modernize your UIKit app | <https://developer.apple.com/videos/play/wwdc2026/278/> |
| News 2026-10-05 | <https://developer.apple.com/news/?id=kkphp5qo> |
| Screenshot specs | <https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/> |
| Forums, UIKit Q&A | <https://developer.apple.com/forums/activities/1670080> |
| Forums, Photos and Camera Q&A | <https://developer.apple.com/forums/activities/1659080> |
| Newsroom | <https://www.apple.com/newsroom/2026/09/apple-unveils-iphone-duo/> |

Talk facts come from the transcripts. UIKit API facts and availability come from the DocC JSON behind developer.apple.com/documentation (`introducedAt`), which is the source of every "27.1" below.

## 1. Opting into full screen

- There is no Info.plist key or API for it. The trigger is the SDK the app is built with (T1, Doc: Preparing your app, Prepare checklist):

  | Built with | Result on iPhone Duo |
  | --- | --- |
  | Xcode 26 or earlier (iOS 26 SDK or older) | Runs in a compatibility mode. Closed: uses the area left of the status bar and camera. Open: a familiar iPhone size and aspect ratio. Does not extend under the status bar and camera. |
  | Xcode 27.0 (iOS 27 SDK), Liney's current toolchain | Resizes to fill the inner display except the status bar area on the side. Does not extend to the screen edge. |
  | Xcode 27.1 (iOS 27.1 SDK) or later | Recommended. App extends to the screen edge. Standard navigation and toolbar buttons lay out vertically under the status bar. |

- Xcode 27.1 is required to run the Duo simulator and Device Hub poses. Liney would move from Xcode 27.0 to 27.1.
- The deployment target does not have to rise. Every Duo-only API below is `introducedAt: 27.1`, so each use needs `#available(iOS 27.1, *)` (or the SDK-gated equivalent). Check this against the iOS 17 floor.
- `UIRequiresFullScreen` is still honored on Duo, but the app still resizes when the device opens or closes (T1). WWDC26 278 says it is honored on iPhone in resizable environments from iOS 27, and now means discrete resizing that honors supported orientations, not a full opt-out of resizing. Liney does not set it (`LineyTests/JournalEntryFlowTests.swift` asserts it is not true).
- Related side effect, from an Apple staff answer on the forums (<https://developer.apple.com/forums/thread/847872>): iPhone apps are expected to resize on iPad and iPhone Mirroring too, and there is no opt-out. A forum report (<https://developer.apple.com/forums/thread/847881>) saw an iPhone-only app stop resizing on iPad when built with 27.1; staff asked whether it was iPhone-only or had `UIRequiresFullScreen`, and the thread has no resolution. Liney is universal (`TARGETED_DEVICE_FAMILY = "1,2"` in `Liney.xcodeproj/project.pbxproj`), so it is probably unaffected. Unconfirmed.
- The UIScene lifecycle is required when building with the latest SDKs; without it the app does not launch (WWDC26 278). Not a Duo-only point, but it gates the SDK bump.
- Idiom: iPhone Duo reports `.phone`. Declaring iPad in the device family is not required (<https://developer.apple.com/forums/thread/847945>, staff). There is no API to detect an iPhone Duo; staff recommend no device-specific behavior (<https://developer.apple.com/forums/thread/847775>).

## 2. Size classes

From T1 and T6:

| Context | Horizontal | Vertical |
| --- | --- | --- |
| Outer display, portrait | compact | regular |
| Outer display, landscape | compact | compact |
| Inner display (open) | regular | regular |
| Split View, 50/50 on the inner display | Not stated in any source read. Apple only says to design for size classes and the space available, and to test it in Device Hub. Unconfirmed. | Not stated. |

- Read them from `traitCollection.horizontalSizeClass` and `.verticalSizeClass`, ideally with automatic trait tracking (Doc: Preparing your app).
- Do not branch on `userInterfaceIdiom` or `UIInterfaceOrientation` for layout. The inner display does not honor supported interface orientations (T1). The outer display behaves like any other iPhone, and landscape support is encouraged because people stand the device like a tent.
- Folding and unfolding is a size-class and trait change, not a scene disconnect or app termination. This appears in forum answers returned by search but could not be traced to a primary page that returned text. Forum thread 847959, "Does folding send the same scene callbacks as backgrounding the app?", is still unanswered. Treat as unconfirmed, and do not rely on fold events producing `sceneDidEnterBackground`.
- Apple staff on the forums (<https://developer.apple.com/forums/thread/847903>): size classes are the supported way to tell the displays apart; do not use a Duo-specific trait or screen.

## 3. Safe areas, margins, edge controls

- Horizontal bars provide top and bottom insets. Vertical bars provide leading and trailing insets (T1).
- Safe areas are often asymmetric. A vertical bar can sit on the left in landscape and in Split View. Never write `bounds.width - safeAreaInsets.left * 2`; use `view.bounds.inset(by: view.safeAreaInsets)` (T1).
- Layout margins are asymmetric too, so foreground content can sit closer to vertical buttons and the status bar while keeping the margin on the opposite side (T1).
- Foreground controls go inside the safe area. Background art (full-bleed images) may fill `view.bounds` (T1).
- The outer display is wider and shorter. Controls move to the right in portrait; on the inner display they stay on the side in landscape, and the inner display in portrait keeps horizontal bars (T6, HIG).
- In Split View each app puts controls on its outer edge, so the left app has controls on the left (T6, HIG). Bars stay on the same hardware side in right-to-left languages (T2, HIG).
- Corners: use `UICornerConfiguration` (iOS 26 concentricity), updated for Duo screen shapes (T1).
- Bar APIs, all UIKit (T2, Doc: Preparing your app):
  - Use `UINavigationController` / `UITabBarController` bars. Custom bars built from `UIToolbar`, `UINavigationBar`, `UITabBar` do not get vertical layout.
  - `UITraitCollection.verticalBarEdge` (`UIVerticalBarEdge`: `.leading`, `.trailing`, `.unspecified`), iOS 27.1.
  - `UIViewController.preferredVerticalBarBehavior` to disable vertical bars; `UISheetPresentationController.preferredPlacement` for sheets on the inner display.
  - `UIBarButtonItem.axisBehavior`, `.visibilityPriority`; `UINavigationItem.leadingItemGroups`, `.pinnedTrailingGroup`, `.additionalOverflowItems`.
  - `UIBackgroundExtensionView` to extend a hero image under a vertical bar.
  - `UITabBarController`: the tab bar is vertical or horizontal by default; a sidebar is opt-in via `tabBarController.sidebar.preferredPlacement = .sidebar` (T1; staff confirm at <https://developer.apple.com/forums/thread/847912>).
- Known beta issue: a leading vertical bar adds an 84 pt leading safe-area inset inside `UINavigationController` that the window does not have, and bar layout guides resolve against it. Apple staff called it a bug (FB24906205, <https://developer.apple.com/forums/thread/847784>).

## 4. Reserved regions

The hinge ("folding region") and the two cameras are reserved regions (HIG, Doc: Preparing your app):

- Outer front camera: always present, expands into the Dynamic Island for Live Activities. It is an occlusion.
- Inner front camera: under the display, present only while the camera is active. It is an occlusion.
- Fold: a division, active only when the device is partially open, zero width when flat.

UIKit API (all iOS 27.1; HIG and Doc: Preparing your app; T3 for the usage):

- `UIView.reservedRegions(kind:options:) -> [UIView.ReservedRegion]`
- `UIView.ReservedRegion` with `frame`, `margins`, `isActive`, `kind`
- `UIView.ReservedRegion.Kind`: `.division`, `.occlusion`
- `UIView.ReservedRegion.QueryOptions`: `.includeInactive`
- SwiftUI equivalents: `ReservedRegion`, `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)`. The T1 talk calls the UIKit type "UIViewReservedRegion"; the HIG and DocC name is `UIView.ReservedRegion`.

Notes:

- Query the view, not the screen. Apple staff on re-layout (<https://developer.apple.com/forums/thread/847876>): call `reservedRegions(kind:options:)` from layout, and use a `UIHingeInteraction` to be told when the pose changes.
- Division regions are for keeping interactive elements out of the fold. Scrollable content does not need to avoid it (T3, T6).
- System components (alerts, menus, sheets, toolbar buttons, split views) nudge themselves away from the fold. Use them rather than custom views (T6).
- Known beta issue: reserved regions and hinge detection do not work in keyboard extensions (forum thread 847963; FB24979539, FB24883137). Not relevant to Liney unless it ships a keyboard extension.
- Layout container for two panes: `UIArrangementViewController` (iOS 27.1) with `UISplitArrangement` and `UIOverlayArrangement`, set via `updateArrangement(_:animated:)`. Do not nest it in a `UISplitViewController`, list or scroll view (T3, Doc: Preparing your app). Optional for Liney.

## 5. Hinge-angle API

- UIKit: `UIHingeInteraction(updateHandler:)` added with `view.addInteraction(_:)`, `isEnabled`. The handler receives a `UIHingeInteraction.Update` whose `hinge: UIHinge?` is `nil` when the interaction is outside a hinge-providing hierarchy or the device has no hinge. All iOS 27.1 (UIKit DocC: `UIHingeInteraction`).
- `UIHinge.angle: CGFloat` in radians; update rate and precision are system policy. `UIHinge.status` is `UIHinge.Status`: `.closed`, `.partiallyOpen`, `.fullyOpen`, `.unknown`. DocC says prefer `status` over `angle` if the discrete state is enough.
- SwiftUI: `onHingeChange(isEnabled:_:)` delivering `DeviceHingeContext` (T4, forum 847876).
- T4: the angle is for driving interactions and effects (their example is a whammy-bar pitch bend). For layout use arrangement and reserved-region APIs, not the angle.

A journal app has no obvious use for the angle. The reserved-region and size-class path covers layout.

## 6. Split View multitasking and requesting new scenes

- Every iPhone app takes part in multitasking on Duo: two apps side by side, 50/50 (T4, T6). Apps resize like iPad or iPhone Mirroring (T1, T4). The system also stacks a pinned Picture-in-Picture video above an app and the app resizes vertically (T6).
- Duo is the first iPhone to support multiple instances of an app's UI. If the app supports multiple scenes on iPad, it does on Duo. New windows can only be created on the inner display. On the outer display they cannot (T4). This availability changes at runtime.
- What T4 tells you to do: handle errors when requesting new scenes, and use `UIWindowScene.ActivationAction` (DocC title; the talk says `UIWindowSceneActivationAction`), which hides itself automatically when new windows are unavailable. Its `alternate:` parameter is "an alternate action to display on iPhone and apps that don't support multiple windows" (DocC). `UIApplication.requestSceneSessionActivation(_:userActivity:options:errorHandler:)` takes an `errorHandler`. `UIApplication.supportsMultipleScenes` is the existing runtime flag (true only when the system allows it and `UIApplicationSupportsMultipleScenes` is true in Info.plist).
- Not stated by Apple in the sources read: the exact error domain or code for a refused request on the outer display, and whether `supportsMultipleScenes` flips when the device closes. Test on the simulator. Unconfirmed.
- A full-screen modal (`modalPresentationStyle = .fullScreen`) fills only the app's scene in Split View, not the display (<https://developer.apple.com/forums/thread/847874>, staff).
- Sheets: outer display has vertical bars by default; inner display centers sheets and keeps horizontal bars; sheets slide to the leading edge when folded; `preferredPlacement` applies at all times, not only when folded (staff, <https://developer.apple.com/forums/thread/847797>).

## 7. Scene accessories and their limits

- UIKit: `UISceneAccessory` (iOS 27.0), registered with `UIViewController.registerSceneAccessory(_:) -> UISceneAccessoryRegistration` (iOS 27.0). `UISceneAccessoryRegistration` has `isAvailable` and `isEnabled`, observable in `updateProperties` / `layoutSubviews`. Unregister with `unregisterSceneAccessory(_:)`.
- Only two kinds exist in the DocC topic list:
  - `UISceneAccessory.externalNonInteractive(sceneConfiguration:)` (iOS 27.0): non-interactive content on an external display.
  - `UISceneAccessory.cameraCapture(sceneConfiguration:)` and `cameraCapture(sceneConfiguration:userInfo:)` (iOS 27.1): content on the Duo outer display. The session role `UISceneSession.Role.windowCameraCaptureAccessory` (27.1) is assigned by the system, and scene-manifest entries for it have no effect.
- Limits (T4 and the AVFoundation article "Registering a camera capture accessory on iPhone Duo"):
  - The camera accessory shows only while the app is full screen on the inner display, foregrounded, with an active capture session. It disappears when capture stops, the app leaves the foreground, or the device closes.
  - The system decides when and where. The app declares content and passes no display or session. The system presents the top-most registration of a kind. Treat it as an enhancement; the app must work without it.
  - Accessory content is on by default. People toggle it with an app control that sets `isEnabled`; do not unregister.
  - The Simulator has no camera, so test on device.
- This is irrelevant to Liney as a journal app unless it adds in-app capture. Liney imports photos; the Photos and Camera Q&A (<https://developer.apple.com/forums/activities/1659080>) covers camera capture only, with no PHPicker or photo-library thread found.

## 8. Screen-reference deprecations

- `UIScreen.main` is deprecated as of iOS 26.0 (DocC: "Use a UIScreen instance found through context instead (i.e, view.window.windowScene.screen)..."). T1 says referencing the main screen is ambiguous on a two-display device and "will be deprecated in a future release" (the DocC page already shows the iOS 26.0 deprecation, so treat T1's wording as loose).
- Replacements (T1, Prepare checklist, WWDC26 278, staff on <https://developer.apple.com/forums/thread/847909>): use the most local information first (a view's `bounds` or `traitCollection`, e.g. `traitCollection.displayScale` for scale), then `window.windowScene.screen`, then scene geometry. Avoid `UIWindow(frame: UIScreen.main.bounds)`; use `UIWindow(windowScene:)`.
- Also stop reading `UIDevice.current.orientation`, `statusBarOrientation`, `interfaceOrientation` and `windowScene.effectiveGeometry.interfaceOrientation` for layout, and device-specific sizes such as `bounds.height == 844` (Prepare checklist).
- In Liney's repo, `UIScreen.main` appears only in tests (`LineyTests/AppLockTests.swift`, three `UIWindow(frame: UIScreen.main.bounds)` calls), found by `git grep` on this branch. Nothing in app code.

## 9. Device Hub and the simulator

- Xcode 27.1 adds the iPhone Duo simulator (T1). Run it in Device Hub and use the controls at the bottom of the screen to open, close, rotate and fold. HIG: Device Hub previews poses.
- Split View is previewed on the inner display by dragging the app by the home indicator to one side (T1).
- Add via Device Hub, "+", iPhone, iPhone Duo (forum <https://developer.apple.com/forums/thread/847137>, community reports). Early 27.1 betas needed the iOS 27.1 runtime re-downloaded under Settings, Components. Several users report the Duo simulator is heavy on memory.
- Apple's checklist also recommends the iOS resizable simulator in Device Hub and iPhone Mirroring on macOS 27 (resize to extremes), and the Xcode "App Resizability" skill (`xcrun agent skills export`) (Prepare checklist, T1).
- A 26.x-built app can be previewed in compatibility mode on the 27.1 simulator (staff, <https://developer.apple.com/forums/thread/847860>).
- Simulator has no camera. Only device evidence covers camera behavior, and (per CLAUDE.md) only device evidence closes release gates.

## 10. App Store screenshot and review requirements

- Duo screenshot sizes (Screenshot specs, retrieved 2026-10-07): outer display 1398 x 2034 portrait / 2034 x 1398 landscape; inner display 2007 x 2853 portrait / 2853 x 2007 landscape. No alpha channel, 1 to 10 screenshots, `.jpeg`/`.jpg`/`.png`.
- Today the spec page lists Duo sizes but the "required device sizes" list is unchanged (iPhone with Dynamic Island medium display, plus iPad 13-inch if the app supports iPadOS). The Duo sizes have no mandatory flag on that page. Apple's news post (2026-10-05) says: "Starting April 2027, any apps or games submitted will need to include screenshots for iPhone Duo."
- Apple's news post says you can submit Duo-optimized apps in App Store Connect today, and App Store Connect has a preview tool to visualize screenshots and product page headers on Duo. Landing page and checklist add a featuring nomination in App Store Connect.
- I did not find any separate App Review requirement for Duo support (no new App Review Guidelines text read). Unconfirmed; the guidelines were not fetched.

## 11. Device availability

- Announced 2026-09-09. Pre-orders open Friday 2026-10-16, 5 a.m. PT. In stores Friday 2026-10-23 (Apple Newsroom: <https://www.apple.com/newsroom/2026/09/apple-unveils-iphone-duo/>, returned by search; Apple Developer news 2026-10-05 states "available to customers starting October 23, 2026"). From $1,999 (US), 70+ countries and regions at launch. The "28 more countries on October 30" detail came only from a third-party result (9to5Mac/MacRumors), not an Apple page, so it is unconfirmed.
- Xcode 27.1 was at RC as of the landing page.

## 12. Other facts worth keeping

- Tab bar and toolbar compression: `UIVerticalBarCompressionBehavior` and `verticalBarCompressionBehavior` on `UINavigationItem` (T2, HIG). Toolbar items with only text, custom views, or an image/title that changes (e.g. system edit button) stay on the horizontal axis.
- Items overflow bottom-to-top by default; assign `visibilityPriority` (HIG: `UIBarButtonItemVisibilityPriority`).
- Hinge-aware layout is not required for compliance; "design your app to be freely resizable and you'll be in good shape" (T6).
- Do not tie functionality to a pose (T6, HIG).
- Camera (not applicable to Liney as a journal app unless it adds capture): `AVCaptureDeviceDirectionCoordinator`, `builtInOuterUltraWideCamera`, `builtInInnerUltraWideCamera`, a Virtual Front Camera that is capped at 1080p/60 fps (T5).
- Unanswered at time of reading: forum threads on `sceneDidBecomeActive` during folds (847959), safe-area caching across the fold (847944), idiom per pose (847949, though staff answered `.phone` elsewhere), popover anchors for action sheets on the inner display (847957), and which display a cold launch connects to (847967).

## Fit with Liney (observations only, not a plan)

- Universal target, iOS 17 floor, no `UIRequiresFullScreen`, and no `UIScreen.main` in app code, so the compatibility-mode path should already work and the Xcode 27.1 bump is the main step.
- Liney is multi-scene, so on Duo the new-window path is inner display only; `UIWindowScene.ActivationAction` handles this by hiding itself.
- Everything new is iOS 27.1+ API and needs availability gating against the iOS 17 deployment target.
