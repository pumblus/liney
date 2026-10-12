# Editor and Photos

This document owns the editor content model, text block interactions, photo selection, automatic grid layout, and photo metadata handling.

- Scope: [SCOPE.md](../../SCOPE.md)
- Domain Terms: [GLOSSARY.md](../../GLOSSARY.md)
- Code Mapping: `EntryEditorView.swift`, `PhotoStorage.swift`, `JournalModels.swift` (see [architecture.md](../agents/architecture.md))

## 1. Stories & Acceptance Criteria

### Writing & Editor Interactions
- **Story 4**: Create an entry quickly with current date/time.
- **Story 5**: Optional title field ("Title (optional)").
- **Story 6**: Plain text body with visible empty-body hint; the last body field fills available height.
- **Story 7**: Auto-save edits immediately to model; coalesce disk writes.
- **Story 8**: Tap Done to dismiss keyboard or leave editor.
- **Story 9**: Silently discard blank new entries on leaving.
- **Story 10**: Written content becomes a normal entry immediately; no separate draft state.
- **Story 11**: Open an entry directly for editing from timeline.

### Photo Selection & Insertion
- **Story 21**: Insert photos from system library via `PHPickerViewController`.
- **Story 22**: Copy selected photos into Liney app sandbox so entries survive deleted originals.
- **Story 23**: Insert photos between text blocks while writing.
- **Story 24**: Keep photos from one picker selection together as a Photo Group.
- **Story 25**: Automatically focus the following text block after photo insertion to continue writing.
- **Story 26**: Lay out Photo Groups automatically based on photo count.
- **Story 27**: Display a single photo full-width.
- **Story 28**: Display two, three, and four photos in balanced automatic grids.
- **Story 29**: Display five or more photos in a dense three-column grid.
- **Story 30**: Preserve photo selection order.

### Photo Information & Metadata Privacy
- **Story 31**: Read photo capture time when available in image metadata.
- **Story 32**: Preserve photo GPS coordinates in database even without a place name.
- **Story 33**: Accept photos without metadata gracefully.
- **Story 34**: Keep GPS-only coordinates internal; never display raw lat/long in normal UI.
- **Story 35**: Ask before replacing entry time/location with photo info.
- **Story 36**: Show automatic Photo Info prompt at most once per entry (`hasShownPhotoInfoPrompt`).
- **Story 37**: Allow user to choose Keep Entry Info when photo metadata differs.
- **Story 38**: Allow manually applying Photo Info later from full-screen photo detail.
- **Story 39**: Preserve each photo's own metadata independently from entry metadata.

### Photo Detail & Entry Information
- **Story 40**: View photos full-screen within the entry flow.
- **Story 41**: Keep photo detail controls simple and dismissible (Done, ellipsis menu, metadata display).
- **Story 42**: Confirm photo deletion with destructive alert.
- **Story 43**: Edit entry date and time using system `UIDatePicker` form.
- **Story 44**: Support all-day entries (date-only picker; toggling off retains calendar day and uses current local time).
- **Story 45**: Show entry location only when present.
- **Story 46**: Exclude manual place search.

## 2. Implementation Decisions

### Content Representation & Persistence
- Journal entries consist of `Entry`, `Block`, and `Photo` models in SwiftData.
- Blocks preserve vertical ordering of text and photo groups.
- Empty text blocks are transient editor state and are never persisted.
- Adjacent text blocks with no media between them are merged internally.
- Each editor operates within its own `ModelContext` to isolate edits from imports or background tasks.

### Text & Checklist Behavior
- The editor is strictly plain-text blocks and photo-group blocks. General rich text, Markdown rendering, captions, manual layout, and block dragging are out of scope.
- **Interactive Checklists**: Interactive checklist items within text blocks are supported. Checked/unchecked states persist as leading `☑ ` / `☐ ` text markers. Tapping the native checkbox toggles the marker, autosaves, and exposes accessible accessibility actions.

### Photo Storage & Compression
- Selected photos are transcoded and copied into the app sandbox as compressed JPEGs (target 2400 px long edge, ~0.85 quality).
- Never store Photos library local identifiers as the primary image reference.
- Decoding runs off the main actor with cancellable requests. Reused views verify request identity before presenting images.

### Automatic Grid Layout
- **1 photo**: Full width, aspect-fit preserving decoded aspect ratio (clamped to 0.5–2.0). Height capped at ~70% visible viewport height.
- **2 or 4 photos**: 2-column square grid.
- **3 photos**: 3-column square grid (avoids trailing empty cell).
- **5+ photos**: 3-column square grid.

### Photo Info Prompt Rules
- Prompt triggers only when the first added photo contains time or location that meaningfully differs from current entry info:
  - Time differs by > 12 hours, OR
  - Location differs by > 1 km, OR
  - Entry has no location while photo has GPS coordinates.
- If multiple photos have conflicting locations, do not update entry location automatically.
- Prompt options: *Use Photo Info*, *Keep Entry Info*, *Cancel*. Dismissing or choosing any option sets `hasShownPhotoInfoPrompt = true`.
- **Privacy constraint**: Do not reverse-geocode GPS coordinates via Apple servers. GPS coordinates remain strictly local.

### Deletion & Rollback
- Row-level swipe deletion requires permanent deletion confirmation.
- On deletion, database changes commit first; sandbox photo files are removed from disk only after successful context save.
