# Liney MVP

This document owns the frozen product scope, core invariants, and capability index.

- **Domain Terms**: [GLOSSARY.md](GLOSSARY.md)
- **Code Architecture**: [docs/agents/architecture.md](docs/agents/architecture.md)
- **Verification Gates**: [release.md](release.md)

MVP scope is frozen; any new product surface requires an explicit user-approved scope update recorded here.

## 1. Problem & Solution

People seeking a calm, lightweight personal journal are often forced into heavy apps with accounts, subscriptions, sync complexity, and intrusive metadata.

Liney is a lightweight, local-first iOS/iPadOS journal for text entries with photos. It provides a calm, Apple-native experience with local-only persistence, Day One archive import, Markdown export, Face ID / Touch ID protection, and English / Simplified Chinese localization. Liney deliberately avoids accounts, cloud sync, analytics, rich text, and speculative product surface.

## 2. Core Invariants

- **Local-Only & Private**: All content persists locally via SwiftData and the app sandbox. No account, cloud backend, analytics, or tracking SDKs.
- **Apple Native**: Minimum target iOS/iPadOS 17 through 27.1, built with Xcode 27.1. Built exclusively with system UIKit components (Split View root, system navigation, SF Symbols). Liney Aqua is strictly an accent/tint, never a full-screen background.
- **Content Model**: Journal entries consist of plain-text blocks and photo groups. No rich text, Markdown rendering in-editor, captions, or manual block reordering. (Exception: interactive checklist text markers `☑ ` / `☐ ` are supported within text blocks).
- **Single Journal**: All entries live in one unified timeline sorted descending by `entryDate`.

## 3. Capabilities & Acceptance Index

Story numbers are stable acceptance references. Detailed specifications live in disclosed companion documents.

### Timeline, Writing & Search (#1–#20)
- **Launch & Timeline (#1–#3, #13–#18)**: Launches directly into timeline with no splash/account. Entries grouped and sorted by `entryDate` (including all-day entries). Rows display text previews and photo thumbnails. Empty state provides direct New Entry and Import Journal actions. Native trailing swipe to delete with permanent confirmation.
- **Writing & Editor (#4–#12)**: Fast entry creation defaulting to current date/time. Optional title and plain text body filling available height. Auto-saves continuously; blank new entries discarded on exit. No draft area.
- **Search (#19–#20)**: Searches title and body text off the main actor; results render in standard timeline rows sorted descending by date.
- *Detailed writing behavior & block rules*: [docs/specs/editor-and-photos.md](docs/specs/editor-and-photos.md)

### Photos & Layout (#21–#46)
- **Stories**: Library photo insertion (#21–#25), automatic balanced grid layouts (#26–#30), photo capture time and GPS metadata handling (#31–#39), full-screen photo detail and date/time editing (#40–#46).
- **Specification**: [docs/specs/editor-and-photos.md](docs/specs/editor-and-photos.md) covers JPEG sandbox copying, multi-photo grid rules, photo-info prompt conditions, and privacy constraints (no server reverse-geocoding).

### Day One Import (#47–#53)
- **Stories**: Day One JSON ZIP import (#47), archive preflight (#48), foreground cancellable progress (#49), immediate chunked commits (#50), deduplication by source ID (#51), unsupported media tolerance (#52), multi-journal merging (#53).
- **Specification**: [docs/specs/day-one-import.md](docs/specs/day-one-import.md) covers preflight verification, deduplication, photo recovery, Markdown mapping, and on-device error reporting.

### Markdown Export (#54–#57)
- **Export Packaging (#54–#56)**: Exports a portable Markdown zip named with export date via system share sheet. Generates one Markdown file per entry with front matter (date, all-day, location, coordinates) and relative JPEG media references.
- **Export Security (#57)**: Requires fresh biometric/passcode authentication if App Lock is enabled. Cancellation aborts export only.

### App Lock & Privacy (#58–#61, #77–#78)
- **Stories**: Optional biometric/passcode lock (#58), content concealment (#59), app-switcher snapshot covering (#60), static privacy copy (#61), app-wide multi-window lock sync (#77), isolated export cancellation (#78).
- **Specification**: [docs/specs/app-lock.md](docs/specs/app-lock.md) covers `LocalAuthentication`, global scene lock state, snapshot privacy shields, and privacy text.

### Adaptation, Windows & iPhone Duo (#62–#63, #69–#76)
- **Stories**: Width-adaptive navigation (#62–#63), iPhone Duo dual-display & Split View (#69–#70), fold avoidance (#71), photo detail split (#72), seamless outer display continuation (#73), dedicated entry windows (#74), single-editor invariant (#75), window state restoration (#76).
- **Specification**: [docs/specs/duo-and-windows.md](docs/specs/duo-and-windows.md) covers split-view collapse/expand transitions, iOS 27.1 fold avoidance calculations, multi-window scene coordination, and UUID restoration.

### Accessibility, Localization & Distribution (#64–#68)
- **Accessibility & System Integration (#64–#66)**: Comprehensive VoiceOver support, Dynamic Type adaptation, and system dark mode adherence across all screens.
- **Localization (#67)**: Full UI localization in English and Simplified Chinese (`zh-Hans`). Dates and locations respect system locale.
- **Distribution (#68)**: Free release without in-app purchases, subscriptions, or ads. `ZIPFoundation` is the sole approved third-party dependency.

## 4. Guardrails & Non-Goals

The following areas are explicitly excluded from the MVP scope:
- **Cloud & Accounts**: No iCloud sync, remote servers, user accounts, analytics, or tracking SDKs.
- **Rich Media**: No audio, video, PDF, generic file attachments, in-app camera, or photo captions.
- **Complex Organization**: No tags, multiple journals, reminders, streaks, writing prompts, or AI features.
- **Formatting**: No rich text styles, in-editor Markdown syntax rendering, or manual block drag/reordering.
- **Location Services**: No background location tracking, real-time location permissions, embedded maps, or manual place search.
