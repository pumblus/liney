# Liney MVP

This document owns product scope and architecture; terminology lives in [GLOSSARY.md](GLOSSARY.md). MVP scope is frozen; an explicit user-approved scope change must be recorded here before adding product surface. Use `release.md` for verification and distribution gates.

## Problem Statement

People who want a lightweight private journal can feel forced into heavier products that include accounts, sync, extra metadata, subscriptions, or too much interface. The early Liney user wants a Day One-like place to keep words and photos, but with a calmer Apple-native experience, local-only data, no account, and enough import/export support to trust the app before using it for real journaling.

## Solution

Build Liney as a lightweight local-first iOS/iPadOS journal for text entries with photos. The MVP lets users write and edit journal entries, insert photo groups between plain text blocks, import an existing Day One JSON zip, export a Markdown zip, search title/body text, protect the app with Face ID/passcode, and use the app in English or Simplified Chinese. The app stays Apple-native, privacy-forward, and intentionally small: no cloud sync, accounts, analytics, rich text, tags, reminders, or speculative product surface.

## Product outcomes

Story numbers are stable acceptance references. Detailed behavior and thresholds follow under Implementation Decisions.

### Launch, writing, and timeline

1. Start without an account.
2. Store the journal on this device, without sending writing to a server.
3. Open directly to the journal timeline on every launch, including a fresh install, without a separate welcome screen. Use the timeline’s New Entry button and Import Journal menu action (scope change approved on 2026-09-18).
4. Create an entry quickly.
5. Allow an optional title.
6. Use a plain text body.
7. Auto-save entries.
8. Provide Done to leave the editor.
9. Silently discard blank new entries.
10. Treat written content as a normal entry immediately; there is no draft area.
11. Open an entry directly for editing.
12. Confirm entry deletion.
13. Sort the timeline by Entry Date.
14. Group timeline entries by date.
15. Keep all-day entries within their date group.
16. Show recognizable text or photo context in timeline rows.
17. Show photo thumbnails for entries containing photos.
18. Offer writing and import actions in the empty state.

### Search

19. Search entry titles and bodies.
20. Use normal timeline rows and navigation for search results.

### Photo insertion and layout

21. Insert photos from the library.
22. Copy selected photos into Liney so entries survive deleted or unavailable originals.
23. Insert photos between text while writing.
24. Keep photos from one selection together as a Photo Group.
25. Continue writing after photo insertion.
26. Lay out Photo Groups automatically.
27. Display a single photo large.
28. Use balanced automatic grids for two, three, and four photos.
29. Use a denser grid for five or more photos.
30. Preserve photo selection order.

### Photo information

31. Read photo capture time when available.
32. Preserve photo GPS even without a place name.
33. Accept photos without metadata.
34. Keep GPS-only coordinates out of normal UI.
35. Ask before replacing entry time/location with Photo Info.
36. Show the automatic Photo Info prompt at most once per entry.
37. Allow keeping Entry Info when photo metadata is inappropriate.
38. Allow applying Photo Info later from photo detail.
39. Preserve each photo's own metadata separately from Entry Info.

### Photo detail and entry information

40. View photos full-screen within the entry flow.
41. Keep photo detail controls simple and dismissible.
42. Confirm photo deletion.
43. Edit entry date/time with system controls.
44. Support all-day entries.
45. Show entry location only when present.
46. Exclude manual place search from MVP.

### Day One import

47. Import a Day One JSON zip.
48. Preflight the archive and confirm before importing.
49. Show foreground import progress and allow cancellation.
50. Commit successfully imported entries immediately so stopping preserves progress.
51. Skip duplicate Day One entry IDs on re-import.
52. Count unsupported media and bad entries while continuing the import.
53. Merge multiple Day One journals into one Liney timeline.

### Markdown export

54. Export a portable Markdown zip.
55. Reference exported photos from Markdown.
56. Use system sharing/file saving so the user chooses the export destination.
57. Require fresh authentication for export when App Lock is enabled.

### App lock and privacy

58. Offer optional Face ID/passcode App Lock.
59. Keep journal content hidden after failed or cancelled authentication.
60. Cover journal content in app-switcher snapshots.
61. Explain local-only privacy in the app.

### Platform, accessibility, and release

62. Use native iPhone navigation and lists.
63. Support basic native iPad split view.
64. Support VoiceOver across writing, browsing, import/export, and App Lock.
65. Adapt the interface to Dynamic Type.
66. Follow system dark mode.
67. Localize the core experience in Simplified Chinese.
68. Release the MVP free, without ads or subscriptions.

## Implementation Decisions

### Platform and native UI

- Build the MVP as a native Apple app with iOS/iPadOS 17 minimum, with iPhone as the primary target and basic iPad split-view support. Adaptation and validation scope is OS 17–27 (OS 27 adaptation approved on 2026-09-18); outstanding runtime and device acceptance is tracked in release.md.
- Follow Apple's Human Interface Guidelines for iOS/iPadOS UI behavior, layout, navigation, accessibility, Dynamic Type, dark mode, and localization.
- Prefer system-native UIKit components and Apple-provided surfaces. Do not introduce a custom UI framework, custom design system, or non-native UI approach for the MVP.
- Check release-facing UI, privacy, metadata, and review notes against the current App Store Review Guidelines before App Store submission.
- Use UIKit-native navigation and controls: navigation stack on iPhone, split view on iPad, system lists and sections for the timeline, system sheets/forms/alerts/confirmation dialogs/menus, UIDatePicker, PHPickerViewController, Share Sheet, and SF Symbols.
- Use Liney Aqua only as the app tint/accent. Do not use it as a full-screen background.
- Keep Settings for persistent preferences and informational pages. Import and export are timeline menu actions, not settings.

### UI ownership and rollback

- Scene composition owns navigation and App Lock presentation. Each editor uses a separate ModelContext so a failed mutation cannot roll back another editor or import; domain operations stay in JournalModels.
- Build with the current iOS SDK and retain the generated scene manifest and launch screen required by OS 27. Flush each editor when its own window scene deactivates; support native resizing and all four iPad orientations without a full-screen compatibility opt-out.
- Timeline loading/search and bounded, cancellable image decoding run off the main actor. Reused image views verify request identity before displaying results.
- Preserve text-input identity during editing and Chinese composition. Apply model edits immediately, coalesce disk saves, and flush on navigation and lifecycle boundaries.
- A UI rollback restores the UI sources and project references together while preserving journal stores, the model schema, and photo directories.

### Local content and persistence

- Represent journal content with Entry, Block, and Photo concepts. Entries own journal metadata; blocks preserve text/photo ordering; photos preserve copied file identity, display order, and extracted metadata.
- Store metadata locally with SwiftData and image files in the app sandbox. Do not store references to Photos library assets as the source of truth.
- Copy selected/imported photos into Liney as compressed JPEGs, targeting a 2400 px long edge and about 0.85 quality.
- Preserve photo capture time and GPS in the database when available. Do not rely on exported image EXIF for Liney's own metadata.
- Use entryDate as the timeline sort date. createdAt and updatedAt are internal bookkeeping and do not become sort options in the MVP.
- New entries default to current date/time, all-day off, and no location.
- Usability update approved on 2026-09-21: show “Title (optional)” and a visible empty-body hint; the last body field fills the available writing area. On compact/iPhone layouts, new and existing entries use the native navigation stack with interactive back navigation and autosave; discard blank new entries on leaving. Expanded iPad retains its existing detail/new-entry presentation.
- Empty text blocks are transient editor state and are not persisted. Adjacent text blocks with no media between them are merged internally.
- The editor supports plain text blocks and photo-group blocks only. It does not support rich text, Markdown rendering, captions, manual layout, or block drag/reorder.
- Scope update approved on 2026-09-18: support interactive checklist items within Text Blocks, including Day One imports. Preserve checked/unchecked state as leading `☑ ` / `☐ ` text, display native tappable controls, autosave changes, and expose accessible toggle actions. Existing imported markers gain the same interaction without re-import or a schema migration. This is a checklist exception to plain-text-only editing; general rich text remains out of scope.

### Photo insertion and layout

- Photo insertion splits a focused text block when needed, inserts one photo group for one picker action, and creates/focuses a following text block so writing can continue.
- If no text block is focused during photo insertion, insert the photo group at the end.
- Use automatic photo-group layout: one photo full width, two and four photos in two columns, three photos in three columns to avoid an empty final cell, and five or more photos in three columns.
- Single photos use their decoded aspect ratio (height/width bounded to 0.5–2 for extreme panoramas/scans) with aspect-fit to preserve the full image. Keep the resolved height when releasing offscreen image data; multi-photo grids remain square cells.
- Use PHPickerViewController for ordered library selection without broad photo library access.

### Photo metadata and privacy

- `JournalEntry.hasShownPhotoInfoPrompt` persists prompt suppression and `externalSourceID` persists Day One deduplication identity. `JournalEntry.dayOnePendingPhotos` is optional recovery data; retain this additive field when rolling back import behavior. Removing persisted fields from shipped stores requires an explicit migration; do not delete them in place as a rollback.

- Do not reverse-geocode photo GPS in the MVP: geocoding may send location data to Apple servers. GPS-only location stays internal; imported place names may be shown when provided. Do not request real-time location permission and do not run background location.
- Prompt to update entry info from photo metadata only when the first added photo has useful time/location that meaningfully differs from current entry info: more than 12 hours, more than 1 km, or entry has no location while the photo has one.
- The photo-info prompt offers Use Photo Info, Keep Entry Info, and Cancel. Any dismissed prompt suppresses future automatic prompts for that entry.
- If multiple photos have different locations, do not automatically update the entry main location.

### Photo detail, entry info, and search

- Photo detail is a full-screen modal with Done, an ellipsis menu, optional captured time/location metadata, Use as Entry Info, and Delete Photo.
- Date editing uses a system form with an All-day toggle. All-day entries use date-only picking; non-all-day entries use date and time. Turning All-day off keeps the selected calendar day and uses the current local hour/minute (usability update requested on 2026-09-21).
- Search covers title and body only. Results are normal timeline rows sorted by entry date descending.
- Scope update approved on 2026-09-21: timeline and search-result rows offer a native trailing swipe Delete Entry action. Disable full-swipe execution and require the existing permanent-deletion confirmation. Cancel leaves the entry and photos intact; save failure rolls back metadata, and copied files are removed only after a successful save. If the entry is open in iPad detail, use that editor's deletion flow and clear the detail on success. Rollback removes this UI entry point without changing stores or the schema.

### Day One import

- Import is available from the timeline menu, including when the journal is empty. Import Journal explains how to export a Day One JSON zip with media and the migration limits, then opens the native file importer.
- Day One import supports JSON zip exports. It preflights zip validity, unzip/readability, Day One JSON presence, and entry count before confirmation. Preparation runs off the main actor with visible status and cancellation.
- Day One import runs in the foreground, shows processed count, can be cancelled, commits successful entries immediately, and keeps already imported entries after cancellation.
- Day One dedupe uses the Day One entry id stored as an external source id. Completed duplicates are skipped and not overwritten. Entries with persisted pending-photo records may recover only those photos, retaining existing content and user edits. Recovery uses surviving group/photo/block anchors; if an original following block was removed, photos are appended and the result explains that. Older imports without recovery records remain skipped.
- Day One import maps ordered content to Liney blocks when order is available. Complete Markdown photo markers and bare photo URIs are supported; Markdown becomes readable plain text, with a richText fallback when the text field is empty. If only body plus attachments are available, import one text block followed by photo groups.
- Use an unambiguous leading H1 as the entry title when no explicit title exists. Preserve photo-first order and headings elsewhere as body text. Remove media-boundary blank lines without flattening paragraphs or code indentation. Convert checklist states into Liney's interactive text markers and normalize Markdown separators to readable plain-text separators.
- Day One import includes text, entry date/time, entry location, photos, and photo metadata where available. It skips unsupported media, tags, weather, music, activity, steps, videos, audio, PDFs, and generic file attachments.
- Import completion separately summarizes imported/repaired entries, recovered/failed photos, skipped duplicates, failed entries, unsupported media, and unsupported metadata. A local list identifies failures by source ID, archive entry number and available date with actionable reasons; incomplete results say they need review. No per-item error export is included in the MVP.

### Markdown export

- Export produces a Markdown zip named with the export date. It contains one Markdown file per entry plus referenced JPEG media, with front matter for date, all-day state, location text, latitude, and longitude when available.
- Export does not create PDF or Day One-compatible output in the MVP. It does not cache the zip after sharing.
- If app lock is enabled, export requires fresh LocalAuthentication before packaging.

### App lock

- App lock is optional, uses LocalAuthentication with system passcode fallback, and has no custom PIN/password or timeout setting in the MVP.
- When app lock is enabled, authenticate on cold start and when returning from background. Failed/cancelled auth shows a locked screen with Unlock.
- Cover journal content before the app switcher snapshot.

### Privacy copy, localization, and distribution

- Include a static privacy page explaining that journal data is stored on-device, no account is required, no analytics or advertising data are collected, photos are copied into Liney, and import/export happen only when the user chooses them.
- Localize app UI in English and Simplified Chinese. Imported user content is not translated. Dates and place names follow system locale.
- Prepare App Store metadata in English and Simplified Chinese. Approved metadata drafts are in `release.md`.
- First release is free with no in-app purchases, subscriptions, ads, analytics, tracking SDK, account system, or backend. ZIPFoundation is the approved archive dependency because ZIP correctness is better served by an established library than a custom archive implementation; additional third-party dependencies require explicit approval.

## Testing Decisions

Use `release.md` for affected flow/contract checks and the real-device, real Day One archive, and one-week writing gates.

## Out of Scope

- iCloud sync.
- Mac app.
- Accounts, backend, server storage, ads, analytics, and tracking SDKs. Third-party dependencies beyond the approved ZIPFoundation package require explicit approval.
- Custom encryption beyond system device protection.
- Custom PIN/password.
- App-lock timeout options.
- Video, audio, PDF, generic file attachments, or media beyond photos.
- In-app camera.
- Share extension.
- Widgets, Lock Screen widgets, Control Center, App Shortcuts, Siri, or Home Screen Quick Actions.
- Recent photo suggestions, broad photo library scanning, or automatic photo recommendations.
- Manual place search/editing.
- Embedded maps.
- Weather, music, activity, steps, or other automatic context sources.
- Tags.
- Multiple journals.
- Reminders, streaks, prompts, AI summaries, or AI features.
- Rich text formatting.
- Markdown rendering in the editor.
- Photo captions.
- Manual photo group layout.
- Drag/reorder blocks.
- Split/merge photo groups.
- Custom themes.
- PDF export.
- Day One-compatible export.
- Import-session rollback, temp tables, complex resume, or per-item error report/export.
- App Store monetization in the MVP.

## Further Notes

- The block editor is the largest MVP risk. If implementation confidence is low, prototype it first and verify system text editing behavior, keyboard behavior, accessibility, and auto-save before building the rest of the editor surface.
- Day One import needs real sample exports to confirm JSON shape and media ordering. Build the parser to be tolerant rather than overfitting unsupported metadata.
- Photo metadata extraction should be verified with real photos that include GPS and with iCloud-backed photos, because photo-picker transfer paths may not expose every original metadata field.
- The target App Store privacy label is Data Not Collected, assuming the no-network/no-analytics/no-tracking constraints remain true.
