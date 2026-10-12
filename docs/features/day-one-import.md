# Day One Import

This document owns the Day One JSON ZIP import pipeline, archive preflight, deduplication, content mapping, media recovery, and error reporting.

- Scope: [SCOPE.md](../../SCOPE.md)
- Domain Terms: [GLOSSARY.md](../../GLOSSARY.md)
- Code Mapping: `DayOneImport.swift`, `ImportJournalView.swift` (see [architecture.md](../agents/architecture.md))

## 1. Stories & Acceptance Criteria

- **Story 47**: Import a Day One JSON ZIP archive with media.
- **Story 48**: Preflight the archive and confirm entry count before importing.
- **Story 49**: Display foreground import progress with cancellation support.
- **Story 50**: Commit successfully imported entries immediately in chunks so stopping preserves progress.
- **Story 51**: Deduplicate by Day One entry ID; skip duplicates on re-import.
- **Story 52**: Count unsupported media and invalid entries while continuing the import.
- **Story 53**: Merge multiple Day One journals into the single Liney timeline.

## 2. Implementation Decisions

### Archive Preflight & Execution
- Triggered from timeline menu ("Import Journal"), available even when the journal is empty.
- Displays preflight explanation of requirements (Day One JSON zip export with media) and migration boundaries before launching system document picker.
- Preflight verifies ZIP integrity, read access, presence of Day One JSON schema, and total entry count off the main actor.
- Import runs in the foreground with a processed count progress indicator.
- Cancellable at any time; committed entries are preserved.

### Deduplication & Photo Recovery
- Deduplication keys off the Day One UUID stored in `JournalEntry.externalSourceID`.
- Completed duplicate entries are skipped without overwriting existing content or user edits.
- **Photo Recovery**: If an existing entry contains persisted `dayOnePendingPhotos` metadata, the import attempts to recover those missing photos using surviving block/group anchors. If original surrounding blocks were deleted by the user, recovered photos are appended. Older imports without pending recovery records remain skipped.
- Schema safety: `dayOnePendingPhotos` and `externalSourceID` are additive persistent fields. Never remove them without an explicit database migration.

### Content & Markdown Mapping
- Maps ordered Day One content into Liney blocks:
  - Unambiguous leading H1 header becomes entry title (if no explicit title exists).
  - Headings elsewhere in body text remain plain-text body blocks.
  - Markdown photo markers and bare photo URIs map to Liney Photo Groups.
  - Markdown checklist markers convert into Liney interactive markers (`☑ ` / `☐ `).
  - Normalizes Markdown horizontal rules into plain text separators.
  - Strips empty blank lines adjacent to media boundaries while preserving paragraph and code indentation.
- If only body text and attachment arrays exist without ordering, import produces one text block followed by photo groups.
- If the text field is empty, fallback to readable text extracted from `richText`.

### Supported Scope & Exclusions
- **Extracted**: Text, entry creation date/time, entry location (latitude/longitude/place name where provided), photo media, and photo capture metadata.
- **Skipped**: Non-photo media (videos, audio, PDFs, generic attachments), metadata tags, weather, music, activity, steps, and books.
- Does not reverse-geocode imported coordinates.

### Completion Reporting
- Summarizes results upon completion:
  - Total imported entries
  - Repaired/recovered entries and photos
  - Skipped duplicates
  - Failed entries
  - Skipped unsupported media counts
- Provides an on-device failure list identifying problems by external source ID, archive entry index, and date with actionable error descriptions. No external file export for error logs.
