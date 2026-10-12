# Markdown Export

This document owns Markdown Export: the zip's contents, how it reaches the user, and its App Lock gate.

- Scope: [SCOPE.md](../../SCOPE.md)
- Domain Terms: [GLOSSARY.md](../../GLOSSARY.md)
- Code Mapping: `JournalExport.swift`, `ExportJournalView.swift` (see [architecture.md](../agents/architecture.md))

## 1. Stories & Acceptance Criteria

- **Story 54**: Export a portable Markdown zip.
- **Story 55**: Reference exported photos from Markdown.
- **Story 56**: Use system sharing and file saving, so the user chooses the export destination.
- **Story 57**: Require fresh authentication for export when App Lock is on.

## 2. Implementation Decisions

### Package
- The zip is named with the export date. It holds one Markdown file per entry plus the referenced JPEG photos, linked by relative paths.
- Front matter carries date, all-day state, location text, latitude, and longitude when available.
- The output is Markdown only, with no PDF or Day One-compatible format. The zip is not cached after sharing.

### App Lock Gate
- With App Lock on, export asks for fresh `LocalAuthentication` before packaging. A failed or cancelled attempt cancels the export only and leaves the app unlocked. Details: [app-lock.md](app-lock.md).
