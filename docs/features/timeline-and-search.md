# Timeline & Search

This document owns launch, the timeline, its empty state, search, and entry deletion from the timeline.

- Scope: [SCOPE.md](../../SCOPE.md)
- Domain Terms: [GLOSSARY.md](../../GLOSSARY.md)
- Code Mapping: `TimelineView.swift`, `TimelineRepository.swift` (see [architecture.md](../agents/architecture.md))

## 1. Stories & Acceptance Criteria

### Launch
- **Story 1**: Start without an account.
- **Story 2**: Store the journal on this device, without sending writing to a server.
- **Story 3**: Open directly to the timeline on every launch, including a fresh install, with no welcome screen. The timeline's New Entry button and Import Journal menu action are the starting points.

### Timeline
- **Story 12**: Confirm entry deletion.
- **Story 13**: Sort the timeline by Entry Date.
- **Story 14**: Group timeline entries by date.
- **Story 15**: Keep All-day Entries within their date group.
- **Story 16**: Show recognizable text or photo context in timeline rows.
- **Story 17**: Show photo thumbnails for entries containing photos.
- **Story 18**: Offer New Entry and Import Journal actions in the empty state.

### Search
- **Story 19**: Search entry titles and bodies.
- **Story 20**: Show search results as normal timeline rows with normal navigation.

## 2. Implementation Decisions

### Ordering
- `entryDate` is the only sort key. `createdAt` and `updatedAt` are internal bookkeeping, not sort options.
- Within a day, timed entries come first, newest first; All-day Entries follow.

### Loading & Search
- Timeline loading and search run off the main actor. Only immutable display values cross to UIKit.
- Search covers title and body text only. Results are sorted by Entry Date, newest first.

### Row Deletion
- Timeline and search rows offer a native trailing swipe Delete Entry action. Full-swipe execution is off; the permanent-deletion confirmation always appears.
- Save, rollback, and file cleanup follow the editor's deletion rules in [editor-and-photos.md](editor-and-photos.md). An entry open in iPad detail is deleted through that editor's flow, which clears the detail on success.

### Menus
- Import and export are timeline menu actions. Settings holds persistent preferences and informational pages only.
